defmodule SymphonyEx.WorkspaceTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.SessionStore
  alias SymphonyEx.Workspace

  test "sanitizes workspace path from issue identifier" do
    issue = %Issue{
      id: "1",
      identifier: "SYM 42/alpha",
      title: "Title",
      description: "",
      state: "Todo"
    }

    assert Workspace.path_for_issue("/tmp/workspaces", issue) == "/tmp/workspaces/sym-42-alpha"
  end

  test "rejects paths outside workspace root" do
    assert {:error, {:outside_workspace_root, _}} =
             Workspace.ensure_within_root("/tmp/workspaces", "/tmp/elsewhere")
  end

  test "prepare reuses an existing recoverable workspace session" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    issue = %Issue{id: "1", identifier: "SYM-66", title: "Title", description: "", state: "Todo"}
    path = Workspace.path_for_issue(root, issue)

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(path)

    assert {:ok, session} =
             SessionStore.save(path, %{
               thread_id: "thread-existing",
               turns_executed: 1,
               capability_profile: %{supports_thread_reuse: true},
               recovery_count: 1,
               phase: :running
             })

    shell = fn _cmd, _args, _opts ->
      flunk("git should not run for recoverable workspace reuse")
    end

    assert {:ok, %{path: ^path, reason: {:recover, recovered}}} =
             Workspace.prepare(issue,
               root: root,
               source_repo_path: source_repo_path,
               shell_fun: shell
             )

    assert recovered.session_id == session.session_id
    assert recovered.thread_id == "thread-existing"
    assert File.exists?(SessionStore.session_path(path))
  end

  test "prepare deletes completed session breadcrumbs before recreating a worktree" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    issue = %Issue{id: "1", identifier: "SYM-67", title: "Title", description: "", state: "Todo"}
    path = Workspace.path_for_issue(root, issue)

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(path)

    assert {:ok, _session} =
             SessionStore.save(path, %{
               thread_id: "thread-complete",
               turns_executed: 2,
               capability_profile: %{supports_thread_reuse: true},
               recovery_count: 0,
               phase: :completed
             })

    parent = self()

    shell = fn
      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        send(parent, :pruned)
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\n", 0}

      "git", ["worktree", "add", "--detach", ^path, "HEAD"], [cd: ^source_repo_path] ->
        send(parent, :added)
        {"", 0}
    end

    assert {:ok, %{path: ^path, reason: {:reset, :completed_session}}} =
             Workspace.prepare(issue,
               root: root,
               source_repo_path: source_repo_path,
               shell_fun: shell
             )

    assert_received :pruned
    assert_received :added
    refute File.exists?(SessionStore.session_path(path))
  end

  test "removes stale leftover directory before creating a worktree" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    issue = %Issue{id: "1", identifier: "SYM-77", title: "Title", description: "", state: "Todo"}
    path = Workspace.path_for_issue(root, issue)

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(path)
    File.write!(Path.join(path, "stale.txt"), "leftover")

    parent = self()

    shell = fn
      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        send(parent, :pruned)
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\n", 0}

      "git", ["worktree", "add", "--detach", ^path, "HEAD"], [cd: ^source_repo_path] ->
        send(parent, :added)
        {"", 0}
    end

    assert {:ok, ^path} =
             Workspace.create(issue,
               root: root,
               source_repo_path: source_repo_path,
               shell_fun: shell
             )

    assert_received :pruned
    assert_received :added
    refute File.exists?(Path.join(path, "stale.txt"))
    refute File.exists?(path)
  end

  test "refuses to delete an active worktree path during stale cleanup" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    issue = %Issue{id: "1", identifier: "SYM-88", title: "Title", description: "", state: "Todo"}
    path = Workspace.path_for_issue(root, issue)

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(path)

    shell = fn
      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\nworktree #{path}\n", 0}
    end

    assert {:error, {:worktree_path_already_active, ^path}} =
             Workspace.create(issue,
               root: root,
               source_repo_path: source_repo_path,
               shell_fun: shell
             )

    assert File.exists?(path)
  end

  test "prepare bootstraps source repo url before creating a worktree" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "cache/github.com__example__project")
    issue = %Issue{id: "1", identifier: "SYM-99", title: "Title", description: "", state: "Todo"}
    path = Workspace.path_for_issue(root, issue)
    parent = self()

    shell = fn
      "git", ["clone", "https://github.com/example/project.git", ^source_repo_path], [] ->
        File.mkdir_p!(source_repo_path)
        send(parent, :cloned)
        {"", 0}

      "git", ["remote", "set-head", "origin", "--auto"], [cd: ^source_repo_path] ->
        {"", 0}

      "git", ["symbolic-ref", "refs/remotes/origin/HEAD"], [cd: ^source_repo_path] ->
        {"refs/remotes/origin/main\n", 0}

      "git", ["checkout", "--detach", "refs/remotes/origin/main"], [cd: ^source_repo_path] ->
        {"", 0}

      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        send(parent, :pruned)
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\n", 0}

      "git", ["worktree", "add", "--detach", ^path, "HEAD"], [cd: ^source_repo_path] ->
        send(parent, :added)
        {"", 0}
    end

    assert {:ok, %{path: ^path, reason: :fresh}} =
             Workspace.prepare(issue,
               root: root,
               source_repo_path: source_repo_path,
               source_repo_url: "https://github.com/example/project.git",
               shell_fun: shell
             )

    assert_received :cloned
    assert_received :pruned
    assert_received :added
  end
end
