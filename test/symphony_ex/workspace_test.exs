defmodule SymphonyEx.WorkspaceTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.SessionStore
  alias SymphonyEx.Workspace

  defmodule ClosedIssueTracker do
    def fetch_issue_by_identifier("13", _opts) do
      {:ok, %Issue{id: "13", identifier: "13", title: "Closed", description: "", state: "Closed"}}
    end
  end

  defmodule OpenIssueTracker do
    def fetch_issue_by_identifier("21", _opts) do
      {:ok, %Issue{id: "21", identifier: "21", title: "Open", description: "", state: "Todo"}}
    end
  end

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

      "git", ["rev-parse", "--is-inside-work-tree"], [cd: ^source_repo_path] ->
        {"true\n", 0}

      "git", ["remote", "get-url", "origin"], [cd: ^source_repo_path] ->
        {"https://github.com/example/project.git\n", 0}

      "git", ["fetch", "--all", "--prune"], [cd: ^source_repo_path] ->
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

  test "prepare checks out target branch worktree when issue metadata requires an existing branch" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")

    issue = %Issue{
      id: "1",
      identifier: "SYM-101",
      title: "Title",
      description: "",
      state: "Todo",
      target_branch: "codex/issue-14-design-audit-apply"
    }

    path = Workspace.path_for_issue(root, issue)
    parent = self()

    File.mkdir_p!(source_repo_path)

    shell = fn
      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        send(parent, :pruned)
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\n", 0}

      "git",
      [
        "worktree",
        "add",
        "--track",
        "-B",
        "codex/issue-14-design-audit-apply",
        ^path,
        "refs/remotes/origin/codex/issue-14-design-audit-apply"
      ],
      [cd: ^source_repo_path] ->
        send(parent, :added_target_branch)
        {"", 0}
    end

    assert {:ok, %{path: ^path, reason: :fresh}} =
             Workspace.prepare(issue,
               root: root,
               source_repo_path: source_repo_path,
               shell_fun: shell
             )

    assert_received :pruned
    assert_received :added_target_branch
  end

  test "prepare mirrors detected gstack skills into the worktree" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-test-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    gstack_root = Path.join(root, "gstack-root")

    issue = %Issue{id: "1", identifier: "SYM-102", title: "Title", description: "", state: "Todo"}
    path = Workspace.path_for_issue(root, issue)
    skill_source = Path.join([gstack_root, "gstack-design-review", "SKILL.md"])
    parent = self()
    previous_gstack_root = System.get_env("GSTACK_ROOT")

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(Path.dirname(skill_source))
    File.write!(skill_source, "# gstack skill\n")
    System.put_env("GSTACK_ROOT", gstack_root)

    on_exit(fn ->
      if previous_gstack_root do
        System.put_env("GSTACK_ROOT", previous_gstack_root)
      else
        System.delete_env("GSTACK_ROOT")
      end
    end)

    shell = fn
      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\n", 0}

      "git", ["worktree", "add", "--detach", ^path, "HEAD"], [cd: ^source_repo_path] ->
        File.mkdir_p!(path)
        send(parent, :added)
        {"", 0}
    end

    assert {:ok, %{path: ^path, reason: :fresh}} =
             Workspace.prepare(issue,
               root: root,
               source_repo_path: source_repo_path,
               shell_fun: shell
             )

    assert_received :added
    mirrored_path = Path.join([path, ".agents", "skills", "gstack-design-review"])
    assert File.exists?(mirrored_path)
    assert File.read!(Path.join(mirrored_path, "SKILL.md")) == "# gstack skill\n"
  end

  test "cleanup_inactive_worktrees removes closed issue worktrees" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    worktree_path = Path.join(root, "13")

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(worktree_path)

    assert {:ok, _session} =
             SessionStore.save(worktree_path, %{
               issue_identifier: "13",
               thread_id: "thread-stale",
               turns_executed: 0,
               capability_profile: %{},
               recovery_count: 0,
               phase: :running
             })

    parent = self()

    shell = fn
      "git", ["worktree", "remove", "--force", ^worktree_path], [cd: ^source_repo_path] ->
        send(parent, :removed)
        File.rm_rf!(worktree_path)
        {"", 0}

      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\nworktree #{worktree_path}\n", 0}

      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        {"", 0}
    end

    assert :ok =
             Workspace.cleanup_inactive_worktrees(
               root: root,
               source_repo_path: source_repo_path,
               tracker: ClosedIssueTracker,
               shell_fun: shell
             )

    assert_received :removed
    refute File.exists?(worktree_path)
  end

  test "cleanup_inactive_worktrees removes stale orphan worktrees for open issues when no progress remains" do
    root =
      Path.join(
        System.tmp_dir!(),
        "symphony-workspace-cleanup-#{System.unique_integer([:positive])}"
      )

    source_repo_path = Path.join(root, "source")
    worktree_path = Path.join(root, "21")

    File.mkdir_p!(source_repo_path)
    File.mkdir_p!(worktree_path)

    stale_updated_at =
      DateTime.utc_now() |> DateTime.add(-3_600, :second) |> DateTime.to_iso8601()

    assert {:ok, session} =
             SessionStore.save(worktree_path, %{
               issue_identifier: "21",
               thread_id: nil,
               turns_executed: 0,
               capability_profile: %{},
               recovery_count: 0,
               phase: :running
             })

    stale_session = %{session | updated_at: stale_updated_at}
    File.write!(SessionStore.session_path(worktree_path), Jason.encode!(stale_session) <> "\n")

    shell = fn
      "git", ["worktree", "list", "--porcelain"], [cd: ^source_repo_path] ->
        {"worktree #{source_repo_path}\n", 0}

      "git", ["worktree", "prune"], [cd: ^source_repo_path] ->
        {"", 0}
    end

    assert :ok =
             Workspace.cleanup_inactive_worktrees(
               root: root,
               source_repo_path: source_repo_path,
               tracker: OpenIssueTracker,
               shell_fun: shell,
               stale_orphan_ttl_ms: 60_000
             )

    refute File.exists?(worktree_path)
  end
end
