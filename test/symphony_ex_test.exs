defmodule SymphonyExTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Orchestrator.Lifecycle

  describe "orchestrator bootstrap" do
    test "builds GitHub-first orchestrator opts from workflow config" do
      workflow = """
      ---
      tracker:
        kind: github
        owner: openai
        repo: symphony
        project-number: 7
        lifecycle:
          released:
            success:
              issue-state: closed
              project-status: Done
      workspace:
        root: /tmp/worktrees
        source-repo-path: /tmp/source
      codex:
        command: codex app-server --stdio
      orchestrator:
        issue-identifier: "#42"
        poll-interval-ms: 1500
        max-concurrent: 3
        max-retries: 4
        backoff-base-ms: 2500
      ---

      # Workflow body
      """

      path = write_workflow!(workflow)

      with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
        opts = SymphonyEx.orchestrator_opts_from_workflow!(path)

        assert opts[:tracker] == SymphonyEx.GitHub.Adapter
        assert opts[:workflow_path] == path
        assert opts[:tracker_opts][:owner] == "openai"
        assert opts[:tracker_opts][:repo] == "symphony"
        assert opts[:tracker_opts][:project_number] == 7
        assert %Lifecycle{} = opts[:tracker_opts][:lifecycle]
        assert opts[:workspace_opts][:root] == "/tmp/worktrees"
        assert opts[:workspace_opts][:source_repo_path] == "/tmp/source"
        assert opts[:codex][:command] == "codex app-server --stdio"
        assert opts[:issue_identifier] == "#42"
        assert opts[:poll_interval_ms] == 1500
        assert opts[:max_concurrent] == 3
        assert opts[:max_retries] == 4
        assert opts[:retry_backoff_ms] == 2500
      end)
    end

    test "configure_from_workflow! stores startup opts in application env" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source-repo-path: /tmp/source
      ---
      """

      path = write_workflow!(workflow)
      previous = Application.get_env(:symphony_ex, SymphonyEx.Orchestrator)

      try do
        with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
          opts = SymphonyEx.configure_from_workflow!(path)
          assert Application.get_env(:symphony_ex, SymphonyEx.Orchestrator) == opts
          assert opts[:tracker] == SymphonyEx.GitHub.Adapter
        end)
      after
        restore_app_env(previous)
      end
    end

    test "ensure_runtime_configured loads workflow path from env when app env is empty" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source-repo-path: /tmp/source
      orchestrator:
        issue-identifier: "#77"
      ---
      """

      path = write_workflow!(workflow)
      previous = Application.get_env(:symphony_ex, SymphonyEx.Orchestrator)

      try do
        Application.delete_env(:symphony_ex, SymphonyEx.Orchestrator)

        with_env(
          [
            {"GITHUB_TOKEN", "ghs_test"},
            {"SYMPHONY_WORKFLOW_PATH", path}
          ],
          fn ->
            opts = SymphonyEx.ensure_runtime_configured()
            assert opts[:tracker] == SymphonyEx.GitHub.Adapter
            assert opts[:issue_identifier] == "#77"
            assert Application.get_env(:symphony_ex, SymphonyEx.Orchestrator) == opts
          end
        )
      after
        restore_app_env(previous)
      end
    end
  end

  defp write_workflow!(contents) do
    path =
      Path.join(System.tmp_dir!(), "workflow-bootstrap-#{System.unique_integer([:positive])}.md")

    File.write!(path, contents)
    path
  end

  @tracked_env_vars [
    "TRACKER_KIND",
    "GITHUB_TOKEN",
    "GITHUB_OWNER",
    "GITHUB_REPO",
    "GITHUB_PROJECT_NUMBER",
    "GITHUB_API_URL",
    "GITHUB_GRAPHQL_URL",
    "LINEAR_API_KEY",
    "TEAM_KEY",
    "WORKSPACE_ROOT",
    "SOURCE_REPO_PATH",
    "SYMPHONY_REPO_PATH",
    "GITHUB_ISSUE_IDENTIFIER",
    "ISSUE_IDENTIFIER",
    "SYMPHONY_LOG_FORMAT",
    "LOG_FORMAT",
    "SYMPHONY_LOG_LEVEL",
    "LOG_LEVEL",
    "SYMPHONY_LOG_METADATA",
    "SYMPHONY_LOG_REDACT_KEYS",
    "SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH",
    "SYMPHONY_WORKFLOW_PATH",
    "WORKFLOW_PATH"
  ]

  defp with_env(pairs, fun) do
    keys = Enum.uniq(@tracked_env_vars ++ Enum.map(pairs, &elem(&1, 0)))
    original = Enum.map(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(keys, &System.delete_env/1)

      Enum.each(pairs, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end

  defp restore_app_env(nil), do: Application.delete_env(:symphony_ex, SymphonyEx.Orchestrator)

  defp restore_app_env(value),
    do: Application.put_env(:symphony_ex, SymphonyEx.Orchestrator, value)
end
