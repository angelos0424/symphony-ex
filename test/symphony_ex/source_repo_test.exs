defmodule SymphonyEx.SourceRepoTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.SourceRepo

  test "explicit SOURCE_REPO_PATH wins over SOURCE_REPO_URL" do
    root = tmp_dir!("explicit-wins")
    repo = Path.join(root, "source")
    File.mkdir_p!(repo)

    shell = fn
      "git", ["rev-parse", "--is-inside-work-tree"], [cd: ^repo] -> {"true\n", 0}
      "git", ["clone", _, _], _opts -> flunk("should not clone when explicit path is set")
      "git", ["fetch" | _], _opts -> flunk("should not fetch when explicit path is set")
    end

    assert {:ok, resolved} =
             SourceRepo.resolve_workspace(
               root: Path.join(root, "worktrees"),
               source_repo_path: repo,
               source_repo_url: "https://github.com/example/project.git",
               source_cache_root: Path.join(root, "cache"),
               shell_fun: shell
             )

    assert resolved[:source_repo_path] == repo
  end

  test "bootstraps SOURCE_REPO_URL into cached clone path" do
    root = tmp_dir!("url-bootstrap")
    cache_root = Path.join(root, "cache")
    remote = git_fixture_repo!("project")

    assert {:ok, resolved} =
             SourceRepo.resolve_workspace(
               source_repo_url: remote,
               source_cache_root: cache_root,
               root: Path.join(root, "worktrees")
             )

    assert resolved[:source_repo_path] == Path.join(cache_root, Path.basename(remote))
    assert resolved[:source_cache_root] == cache_root
  end

  test "fetches and validates existing cached clone" do
    root = tmp_dir!("existing-cache")
    cache_root = Path.join(root, "cache")
    repo = Path.join(cache_root, "project")
    File.mkdir_p!(repo)

    shell = fn
      "git", ["rev-parse", "--is-inside-work-tree"], [cd: ^repo] ->
        {"true\n", 0}

      "git", ["remote", "get-url", "origin"], [cd: ^repo] ->
        {"https://github.com/example/project.git\n", 0}

      "git", ["fetch", "--all", "--prune"], [cd: ^repo] ->
        {"", 0}
    end

    assert {:ok, resolved} =
             SourceRepo.resolve_workspace(
               source_repo_url: "https://github.com/example/project.git",
               source_cache_root: cache_root,
               root: Path.join(root, "worktrees"),
               shell_fun: shell
             )

    assert resolved[:source_repo_path] == repo
  end

  test "returns clear error when neither path nor url is configured" do
    assert_raise ArgumentError, ~r/workspace.source_repo_path/, fn ->
      SourceRepo.resolve_workspace!(root: tmp_dir!("missing-source"))
    end
  end

  defp tmp_dir!(label) do
    path = Path.join(System.tmp_dir!(), "#{label}-#{System.unique_integer([:positive])}")
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
end
