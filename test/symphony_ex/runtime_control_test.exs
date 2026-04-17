defmodule SymphonyEx.RuntimeControlTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.{RuntimeControl, WorkflowStore}

  defmodule TickForwarder do
    use GenServer

    def start_link(test_pid) do
      GenServer.start_link(__MODULE__, test_pid)
    end

    @impl true
    def init(test_pid) do
      send(test_pid, {:tick_forwarder_started, self()})
      {:ok, test_pid}
    end

    @impl true
    def handle_info(:tick, test_pid) do
      send(test_pid, :orchestrator_tick)
      {:noreply, test_pid}
    end
  end

  setup do
    previous_runtime = Application.get_env(:symphony_ex, :runtime_config)
    previous_orchestrator = Application.get_env(:symphony_ex, SymphonyEx.Orchestrator)
    previous_store = Application.get_env(:symphony_ex, WorkflowStore)
    previous_endpoint = Application.get_env(:symphony_ex, SymphonyExWeb.Endpoint)

    on_exit(fn ->
      restore_env(:runtime_config, previous_runtime)
      restore_env(SymphonyEx.Orchestrator, previous_orchestrator)
      restore_env(WorkflowStore, previous_store)
      restore_env(SymphonyExWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "applies orchestrator settings to WORKFLOW and reloads the store" do
    workflow_path = write_workflow!()
    store_name = :"workflow_store_#{System.unique_integer([:positive])}"
    orchestrator_name = :"orchestrator_#{System.unique_integer([:positive])}"

    with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
      start_supervised!(
        {WorkflowStore, workflow_path: workflow_path, watcher: false, name: store_name}
      )

      pid =
        start_supervised!(%{
          id: orchestrator_name,
          start: {TickForwarder, :start_link, [self()]}
        })

      Process.register(pid, orchestrator_name)

      assert {:ok, %{settings: settings}} =
               RuntimeControl.apply_orchestrator_settings(
                 %{
                   "poll_interval_ms" => "1500",
                   "max_concurrent" => "3",
                   "max_retries" => "4",
                   "backoff_base_ms" => "2500"
                 },
                 workflow_path: workflow_path,
                 workflow_store: store_name,
                 orchestrator: orchestrator_name
               )

      assert settings.poll_interval_ms == 1500
      assert settings.max_concurrent == 3
      assert settings.max_retries == 4
      assert settings.backoff_base_ms == 2500

      snapshot = WorkflowStore.snapshot(store_name)

      assert snapshot.config[:orchestrator][:poll_interval_ms] == 1500
      assert snapshot.config[:orchestrator][:max_concurrent] == 3
      assert snapshot.config[:orchestrator][:max_retries] == 4
      assert snapshot.config[:orchestrator][:backoff_base_ms] == 2500

      content = File.read!(workflow_path)
      assert content =~ "poll-interval-ms: 1500"
      assert content =~ "max-concurrent: 3"
      assert content =~ "max-retries: 4"
      assert content =~ "backoff-base-ms: 2500"

      assert_receive :orchestrator_tick
    end)
  end

  test "restarts the orchestrator child through the supervisor" do
    workflow_path = write_workflow!()
    store_name = :"workflow_store_#{System.unique_integer([:positive])}"

    with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
      start_supervised!(
        {WorkflowStore, workflow_path: workflow_path, watcher: false, name: store_name}
      )

      {:ok, supervisor} =
        Supervisor.start_link(
          [
            %{
              id: SymphonyEx.Orchestrator,
              start: {TickForwarder, :start_link, [self()]},
              type: :worker,
              restart: :permanent
            }
          ],
          strategy: :one_for_one
        )

      assert_receive {:tick_forwarder_started, first_pid}

      assert {:ok, :orchestrator} =
               RuntimeControl.restart_component(
                 :orchestrator,
                 workflow_path: workflow_path,
                 workflow_store: store_name,
                 supervisor: supervisor
               )

      assert_receive {:tick_forwarder_started, second_pid}
      refute first_pid == second_pid
    end)
  end

  defp write_workflow! do
    root = Path.join(System.tmp_dir!(), "runtime-control-#{System.unique_integer([:positive])}")
    source = Path.join(root, "source")
    worktrees = Path.join(root, "worktrees")

    File.mkdir_p!(source)
    File.mkdir_p!(worktrees)

    path = Path.join(root, "WORKFLOW.md")

    File.write!(
      path,
      """
      ---
      tracker:
        kind: github
        owner: openai
        repo: symphony
      workspace:
        root: #{worktrees}
        source-repo-path: #{source}
      orchestrator:
        max-concurrent: 1
        max-retries: 2
        backoff-base-ms: 1000
        poll-interval-ms: 30000
      dashboard:
        enabled: true
        host: 127.0.0.1
        port: 4000
        secret-key-base: #{String.duplicate("a", 64)}
      ---

      # Workflow body
      """
    )

    path
  end

  @tracked_env_vars ["GITHUB_TOKEN"]

  defp with_env(overrides, fun) do
    previous = Map.new(@tracked_env_vars, &{&1, System.get_env(&1)})

    Enum.each(overrides, fn {key, value} -> System.put_env(key, value) end)

    try do
      fun.()
    after
      Enum.each(@tracked_env_vars, fn key ->
        case Map.get(previous, key) do
          nil -> System.delete_env(key)
          value -> System.put_env(key, value)
        end
      end)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_ex, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_ex, key, value)
end
