defmodule SymphonyEx.WorkflowStoreTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.WorkflowStore

  defmodule MockWatcher do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn -> %{opts: opts, subscribed: false, started: false} end)
    end

    def subscribe(server) do
      Agent.update(server, &Map.put(&1, :subscribed, true))
      :ok
    end

    def start(server) do
      Agent.update(server, &Map.put(&1, :started, true))
      :ok
    end
  end

  setup do
    previous = Application.get_env(:symphony_ex, :workflow_watcher_module)
    Application.put_env(:symphony_ex, :workflow_watcher_module, MockWatcher)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:symphony_ex, :workflow_watcher_module)
      else
        Application.put_env(:symphony_ex, :workflow_watcher_module, previous)
      end
    end)

    :ok
  end

  test "loads config/template and reloads on workflow change" do
    with_env(
      [{"GITHUB_TOKEN", "ghs_test"}, {"GITHUB_OWNER", "openai"}, {"GITHUB_REPO", "symphony"}],
      fn ->
        path = write_workflow!("v1", 1_000)

        {:ok, store} = start_supervised({WorkflowStore, workflow_path: path})

        assert WorkflowStore.get_template(store) =~ "v1"
        assert WorkflowStore.get_config(store)[:orchestrator][:poll_interval_ms] == 1_000

        File.write!(path, workflow_contents("v2", 2_500))
        assert {:ok, _snapshot} = WorkflowStore.reload(store)

        # reload/1 is synchronous — template should already be updated
        assert WorkflowStore.get_template(store) =~ "v2"

        snapshot = WorkflowStore.snapshot(store)
        assert snapshot.template =~ "v2"
        assert snapshot.config[:orchestrator][:poll_interval_ms] == 2_500
        assert snapshot.reload_count == 1
      end
    )
  end

  test "keeps prior snapshot when reload fails validation" do
    with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
      path = write_workflow!("stable", 1_000)
      {:ok, store} = start_supervised({WorkflowStore, workflow_path: path})

      File.write!(
        path,
        "---\ntracker:\n  owner: openai\nworkspace:\n  root:\n    - invalid\n---\nBroken\n"
      )

      assert {:error, _reason} = WorkflowStore.reload(store)

      snapshot = WorkflowStore.snapshot(store)
      assert snapshot.template =~ "stable"
      assert snapshot.config[:orchestrator][:poll_interval_ms] == 1_000
      assert snapshot.reload_count == 0
    end)
  end

  defp write_workflow!(body_text, poll_interval_ms) do
    path = Path.join(System.tmp_dir!(), "workflow-store-#{System.unique_integer([:positive])}.md")
    File.write!(path, workflow_contents(body_text, poll_interval_ms))
    path
  end

  defp workflow_contents(body_text, poll_interval_ms) do
    """
    ---
    tracker:
      owner: openai
      repo: symphony
    workspace:
      root: /tmp/worktrees
      source-repo-path: /tmp/source
    orchestrator:
      poll-interval-ms: #{poll_interval_ms}
    ---

    Prompt #{body_text}: <%= issue.title %>
    """
  end

  defp wait_until(fun, attempts \\ 20)
  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
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
end
