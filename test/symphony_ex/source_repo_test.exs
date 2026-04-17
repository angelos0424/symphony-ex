defmodule SymphonyEx.SourceRepoTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.SourceRepo

  test "explicit SOURCE_REPO_PATH wins over SOURCE_REPO_URL" do
    root = tmp_dir!("explicit-wins")
    repo = Path.join(root, "source")
    File.mkdir_p!(repo)

    assert {:ok, resolved} =
             SourceRepo.resolve_workspace(
               root: Path.join(root, "worktrees"),
               source_repo_path: repo,
               source_repo_url: "https://github.com/example/project.git",
               source_cache_root: Path.join(root, "cache")
             )

    assert resolved[:source_repo_path] == repo
  end

  test "resolve_workspace computes SOURCE_REPO_URL cache path without git side effects" do
    root = tmp_dir!("url-bootstrap")
    cache_root = Path.join(root, "cache")
    remote = git_fixture_repo!("project")

    assert {:ok, resolved} =
             SourceRepo.resolve_workspace(
               source_repo_url: remote,
               source_cache_root: cache_root,
               root: Path.join(root, "worktrees")
             )

    assert resolved[:source_repo_path] ==
             Path.join(cache_root, expected_cache_dir_for(remote))

    assert resolved[:source_cache_root] == cache_root
    refute File.exists?(resolved[:source_repo_path])
  end

  test "ensure_ready bootstraps SOURCE_REPO_URL into cached clone path" do
    root = tmp_dir!("url-bootstrap-ready")
    cache_root = Path.join(root, "cache")
    remote = git_fixture_repo!("project")

    {:ok, resolved} =
      SourceRepo.resolve_workspace(
        source_repo_url: remote,
        source_cache_root: cache_root,
        root: Path.join(root, "worktrees")
      )

    assert :ok = SourceRepo.ensure_ready(resolved)
    assert File.exists?(resolved[:source_repo_path])
  end

  test "ensure_ready fetches and validates existing cached clone" do
    root = tmp_dir!("existing-cache")
    cache_root = Path.join(root, "cache")
    repo = Path.join(cache_root, "github.com__example__project")
    File.mkdir_p!(repo)

    shell = fn
      "git", ["rev-parse", "--is-inside-work-tree"], [cd: ^repo] ->
        {"true\n", 0}

      "git", ["remote", "get-url", "origin"], [cd: ^repo] ->
        {"https://github.com/example/project.git\n", 0}

      "git", ["fetch", "--all", "--prune"], [cd: ^repo] ->
        {"", 0}

      "git", ["remote", "set-head", "origin", "--auto"], [cd: ^repo] ->
        {"network down\n", 1}

      "git", ["symbolic-ref", "refs/remotes/origin/HEAD"], [cd: ^repo] ->
        {"refs/remotes/origin/main\n", 0}

      "git", ["checkout", "--detach", "refs/remotes/origin/main"], [cd: ^repo] ->
        {"", 0}
    end

    assert :ok =
             SourceRepo.ensure_ready(
               source_repo_path: repo,
               source_repo_url: "https://github.com/example/project.git",
               source_cache_root: cache_root,
               shell_fun: shell
             )
  end

  test "matches equivalent GitHub URLs but narrows canonicalization to github.com forms" do
    root = tmp_dir!("normalized-remote")
    cache_root = Path.join(root, "cache")
    repo = Path.join(cache_root, "github.com__exampleorg__project")
    File.mkdir_p!(repo)

    shell = fn
      "git", ["rev-parse", "--is-inside-work-tree"], [cd: ^repo] ->
        {"true\n", 0}

      "git", ["remote", "get-url", "origin"], [cd: ^repo] ->
        {"git@github.com:ExampleOrg/project.git\n", 0}

      "git", ["fetch", "--all", "--prune"], [cd: ^repo] ->
        {"", 0}

      "git", ["remote", "set-head", "origin", "--auto"], [cd: ^repo] ->
        {"", 0}

      "git", ["symbolic-ref", "refs/remotes/origin/HEAD"], [cd: ^repo] ->
        {"refs/remotes/origin/main\n", 0}

      "git", ["checkout", "--detach", "refs/remotes/origin/main"], [cd: ^repo] ->
        {"", 0}
    end

    assert :ok =
             SourceRepo.ensure_ready(
               source_repo_path: repo,
               source_repo_url: "https://github.com/ExampleOrg/project",
               source_cache_root: cache_root,
               shell_fun: shell
             )
  end

  test "fetch_pull_request-compatible target branch refs can rely on fetched remote state without changing cached default head" do
    root = tmp_dir!("existing-cache-target-branch")
    cache_root = Path.join(root, "cache")
    repo = Path.join(cache_root, "github.com__example__project")
    File.mkdir_p!(repo)

    shell = fn
      "git", ["rev-parse", "--is-inside-work-tree"], [cd: ^repo] ->
        {"true\n", 0}

      "git", ["remote", "get-url", "origin"], [cd: ^repo] ->
        {"https://github.com/example/project.git\n", 0}

      "git", ["fetch", "--all", "--prune"], [cd: ^repo] ->
        {"", 0}

      "git", ["remote", "set-head", "origin", "--auto"], [cd: ^repo] ->
        {"", 0}

      "git", ["symbolic-ref", "refs/remotes/origin/HEAD"], [cd: ^repo] ->
        {"refs/remotes/origin/main\n", 0}

      "git", ["checkout", "--detach", "refs/remotes/origin/main"], [cd: ^repo] ->
        {"", 0}
    end

    assert :ok =
             SourceRepo.ensure_ready(
               source_repo_path: repo,
               source_repo_url: "https://github.com/example/project.git",
               source_cache_root: cache_root,
               shell_fun: shell
             )
  end

  test "returns clear error when neither path nor url is configured" do
    assert_raise ArgumentError, ~r/workspace.source_repo_path/, fn ->
      SourceRepo.resolve_workspace!(root: tmp_dir!("missing-source"))
    end
  end

  defp tmp_dir!(label) do
    path = Path.join(System.tmp_dir!(), "#{label}-#{tmp_suffix()}")
    File.mkdir_p!(path)
    path
  end

  defp git_fixture_repo!(name) do
    root = tmp_dir!(name)
    File.write!(Path.join(root, "README.md"), "# fixture\n")
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: root)
    {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: root)
    root
  end

  defp expected_cache_dir_for(url) do
    case String.trim(url) do
      "" ->
        raise "unexpected empty url"

      trimmed ->
        trimmed
        |> String.trim_trailing("/")
        |> String.replace_suffix(".git", "")
        |> :erlang.md5()
        |> Base.encode16(case: :lower)
    end
  end

  defp tmp_suffix do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
