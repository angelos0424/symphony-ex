defmodule SymphonyEx.RuntimeControlGuardTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.{Observability, Orchestrator, RuntimeControl}
  alias SymphonyEx.Domain.Issue

  defmodule BlockingTracker do
    @behaviour SymphonyEx.Tracker

    def fetch_candidate_issues(opts) do
      issues = Keyword.get(opts, :issues, [])
      send(Keyword.fetch!(opts, :test_pid), {:candidate_poll, Enum.map(issues, & &1.identifier)})
      {:ok, issues}
    end

    def fetch_issue_by_identifier(identifier, opts) do
      {:ok, Enum.find(Keyword.get(opts, :issues, []), &(&1.identifier == identifier))}
    end

    def fetch_issue_comments(_issue_id, _opts), do: {:ok, []}
    def create_comment(_issue_id, _body, _opts), do: {:ok, %{}}
    def update_issue_state(_issue, _state_name, _opts), do: {:ok, %{}}
    def update_issue_description(_issue_id, _description, _opts), do: {:ok, %{}}

    def write_run_record(issue, payload, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:run_record, issue.identifier, payload})
      {:ok, %{}}
    end
  end

  defmodule BlockingWorkspace do
    def prepare(issue, opts) do
      path = Path.join(Keyword.fetch!(opts, :workspace_root), issue.identifier)
      File.mkdir_p!(path)
      {:ok, %{path: path, reason: :fresh}}
    end

    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok
    def cleanup_inactive_worktrees(_opts), do: :ok
  end

  defmodule BlockingAgentRunner do
    def run(issue, opts) do
      test_pid = opts |> Keyword.fetch!(:tracker_opts) |> Keyword.fetch!(:test_pid)
      send(test_pid, {:agent_started, issue.identifier, self()})

      receive do
        :release_agents -> %{status: :success, events: [], error: nil}
      end
    end
  end

  defmodule EndpointWorker do
    use GenServer

    def start_link(test_pid), do: GenServer.start_link(__MODULE__, test_pid)

    @impl true
    def init(test_pid) do
      send(test_pid, {:endpoint_started, self()})
      {:ok, test_pid}
    end
  end

  setup do
    ensure_observability_started()
    Observability.reset()

    previous_runtime = Application.get_env(:symphony_ex, :runtime_config)
    previous_orchestrator = Application.get_env(:symphony_ex, SymphonyEx.Orchestrator)
    previous_store = Application.get_env(:symphony_ex, SymphonyEx.WorkflowStore)
    previous_endpoint = Application.get_env(:symphony_ex, SymphonyExWeb.Endpoint)

    on_exit(fn ->
      restore_env(:runtime_config, previous_runtime)
      restore_env(SymphonyEx.Orchestrator, previous_orchestrator)
      restore_env(SymphonyEx.WorkflowStore, previous_store)
      restore_env(SymphonyExWeb.Endpoint, previous_endpoint)
    end)

    :ok
  end

  test "publishes sorted active identifiers and safe structured summaries" do
    issues = [issue_fixture("SYM-2"), issue_fixture("SYM-1")]

    {_supervisor, orchestrator, _workflow_path} =
      start_runtime(
        issues,
        max_concurrent: 2,
        concurrency_limits: %{default: 2, code: 2, docs: 2, infra: 2},
        default_conflict_scope_to_class: false
      )

    wait_until(fn -> map_size(Orchestrator.snapshot(orchestrator).running) == 2 end)

    assert Orchestrator.active_run_identifiers(orchestrator) == ["SYM-1", "SYM-2"]
    assert Orchestrator.active_identifiers(orchestrator) == ["SYM-1", "SYM-2"]

    summaries = Orchestrator.active_runs(orchestrator)
    assert Enum.map(summaries, & &1.identifier) == ["SYM-1", "SYM-2"]

    assert Enum.all?(summaries, fn summary ->
             is_map(summary.task) and summary.task.state == :running and
               is_binary(summary.workspace_path) and
               not Map.has_key?(summary, :prompt) and
               not Map.has_key?(summary, :tracker_opts)
           end)

    refute inspect(summaries) =~ "tracker-secret-token"
  end

  test "rejects active orchestrator restart atomically and preserves run state" do
    issues = [issue_fixture("SYM-2"), issue_fixture("SYM-1")]

    {supervisor, orchestrator, workflow_path} =
      start_runtime(issues,
        max_concurrent: 2,
        concurrency_limits: %{default: 2, code: 2, docs: 2, infra: 2},
        default_conflict_scope_to_class: false
      )

    wait_until(fn -> map_size(Orchestrator.snapshot(orchestrator).running) == 2 end)

    before = Orchestrator.snapshot(orchestrator)
    before_content = File.read!(workflow_path)
    old_pid = Process.whereis(orchestrator)
    old_tasks = Map.new(before.running, fn {identifier, entry} -> {identifier, entry.task} end)

    assert {:error, {:active_runs, ["SYM-1", "SYM-2"]}} =
             RuntimeControl.restart_component(
               :orchestrator,
               workflow_path: workflow_path,
               orchestrator: orchestrator,
               supervisor: supervisor
             )

    assert Process.whereis(orchestrator) == old_pid
    assert File.read!(workflow_path) == before_content

    after_snapshot = Orchestrator.snapshot(orchestrator)
    assert Map.keys(after_snapshot.running) |> Enum.sort() == ["SYM-1", "SYM-2"]

    assert Map.new(after_snapshot.running, fn {identifier, entry} -> {identifier, entry.task} end) ==
             old_tasks

    assert Map.new(after_snapshot.running, fn {identifier, entry} ->
             {identifier, entry.workspace_path}
           end) ==
             Map.new(before.running, fn {identifier, entry} ->
               {identifier, entry.workspace_path}
             end)

    assert [
             %{
               event: "orchestrator_restart_rejected",
               active_identifiers: ["SYM-1", "SYM-2"],
               reason: "active_runs"
             }
           ] =
             Observability.snapshot().audit_events

    refute inspect(Observability.snapshot().audit_events) =~ "tracker-secret-token"
    refute inspect(Observability.snapshot().audit_events) =~ "prompt"
  end

  test "a reserved orchestrator does not dispatch a queued tick" do
    {_supervisor, orchestrator, _workflow_path} = start_runtime([])
    assert_receive {:candidate_poll, []}, 500

    assert {:ok, token} = Orchestrator.reserve_restart(orchestrator)
    send(orchestrator, :tick)

    refute_receive {:candidate_poll, _identifiers}, 100
    refute_receive {:agent_started, _identifier, _pid}, 100
    assert Orchestrator.active_run_identifiers(orchestrator) == []

    assert :ok = Orchestrator.release_restart(orchestrator, token)
  end

  test "releases the reservation when the restart supervisor fails" do
    {_supervisor, orchestrator, workflow_path} = start_runtime([])
    {:ok, unrelated_supervisor} = Supervisor.start_link([], strategy: :one_for_one)

    on_exit(fn ->
      if Process.alive?(unrelated_supervisor), do: Supervisor.stop(unrelated_supervisor)
    end)

    assert {:error, {:component_not_running, :orchestrator}} =
             RuntimeControl.restart_component(
               :orchestrator,
               workflow_path: workflow_path,
               orchestrator: orchestrator,
               supervisor: unrelated_supervisor
             )

    assert {:ok, token} = Orchestrator.reserve_restart(orchestrator)
    assert :ok = Orchestrator.release_restart(orchestrator, token)
  end

  test "restarts an idle orchestrator child while preserving endpoint independence" do
    {orchestrator_supervisor, orchestrator, workflow_path} = start_runtime([])
    old_orchestrator_pid = Process.whereis(orchestrator)

    assert {:ok, :orchestrator} =
             RuntimeControl.restart_component(
               :orchestrator,
               workflow_path: workflow_path,
               orchestrator: orchestrator,
               supervisor: orchestrator_supervisor
             )

    wait_until(fn -> Process.whereis(orchestrator) not in [nil, old_orchestrator_pid] end)

    endpoint_supervisor =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Supervisor, :start_link,
           [
             [
               %{
                 id: SymphonyExWeb.Endpoint,
                 start: {EndpointWorker, :start_link, [self()]},
                 type: :worker,
                 restart: :permanent
               }
             ],
             [strategy: :one_for_one]
           ]},
        type: :supervisor
      })

    assert_receive {:endpoint_started, old_endpoint_pid}, 500
    active_issues = [issue_fixture("SYM-9")]
    {active_supervisor, active_orchestrator, active_workflow_path} = start_runtime(active_issues)
    wait_until(fn -> map_size(Orchestrator.snapshot(active_orchestrator).running) == 1 end)
    active_run = Orchestrator.snapshot(active_orchestrator).running["SYM-9"]

    assert {:ok, :endpoint} =
             RuntimeControl.restart_component(
               :endpoint,
               workflow_path: active_workflow_path,
               orchestrator: active_orchestrator,
               supervisor: endpoint_supervisor
             )

    assert_receive {:endpoint_started, new_endpoint_pid}, 500
    refute new_endpoint_pid == old_endpoint_pid

    assert Process.whereis(active_orchestrator) ==
             active_supervisor
             |> Supervisor.which_children()
             |> find_child_pid(SymphonyEx.Orchestrator)

    assert Orchestrator.snapshot(active_orchestrator).running["SYM-9"].task == active_run.task
  end

  defp start_runtime(issues, opts \\ []) do
    task_supervisor = String.to_atom("guard_tasks_#{System.unique_integer([:positive])}")
    orchestrator = String.to_atom("guard_orchestrator_#{System.unique_integer([:positive])}")

    workspace_root =
      Path.join(System.tmp_dir!(), "guard-workspaces-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    workflow_path = write_workflow!(workspace_root)

    start_supervised!({Task.Supervisor, name: task_supervisor})

    orchestrator_opts = [
      name: orchestrator,
      tracker: BlockingTracker,
      tracker_opts: [test_pid: self(), issues: issues, api_key: "tracker-secret-token"],
      workspace: BlockingWorkspace,
      workspace_opts: [workspace_root: workspace_root],
      agent_runner: BlockingAgentRunner,
      workflow_path: workflow_path,
      poll_interval_ms: Keyword.get(opts, :poll_interval_ms, 60_000),
      max_concurrent: Keyword.get(opts, :max_concurrent, 1),
      concurrency_limits:
        Keyword.get(opts, :concurrency_limits, %{default: 1, code: 1, docs: 1, infra: 1}),
      max_retries: 0,
      retry_backoff_ms: 1,
      max_retry_backoff_ms: 1,
      default_conflict_scope_to_class: Keyword.get(opts, :default_conflict_scope_to_class, true),
      task_supervisor: task_supervisor
    ]

    supervisor =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Supervisor, :start_link,
           [
             [
               %{
                 id: SymphonyEx.Orchestrator,
                 start: {Orchestrator, :start_link, [orchestrator_opts]},
                 type: :worker,
                 restart: :permanent
               }
             ],
             [strategy: :one_for_one]
           ]},
        type: :supervisor
      })

    {supervisor, orchestrator, workflow_path}
  end

  defp issue_fixture(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Test issue #{identifier}",
      description: "",
      state: "Todo"
    }
  end

  defp write_workflow!(root) do
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
        api-key: workflow-tracker-token
        owner: openai
        repo: symphony
      workspace:
        root: #{worktrees}
        source-repo-path: #{source}
      orchestrator:
        poll-interval-ms: 60000
        max-concurrent: 1
        max-retries: 0
        backoff-base-ms: 1
      ---
      # Workflow
      """
    )

    path
  end

  defp ensure_observability_started do
    if Process.whereis(Observability) == nil do
      start_supervised!({Observability, name: Observability})
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:symphony_ex, key)
  defp restore_env(key, value), do: Application.put_env(:symphony_ex, key, value)

  defp find_child_pid(children, child_id) do
    Enum.find_value(children, fn
      {^child_id, pid, _type, _modules} -> pid
      _other -> nil
    end)
  end

  defp wait_until(fun, attempts \\ 100)

  defp wait_until(fun, attempts) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end
end
