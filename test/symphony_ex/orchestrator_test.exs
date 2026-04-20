defmodule SymphonyEx.OrchestratorTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Domain.{Events, Issue}
  alias SymphonyEx.Orchestrator

  defmodule Control do
    use Agent

    def start_link(opts) do
      Agent.start_link(
        fn ->
          %{
            candidate_batches: Keyword.get(opts, :candidate_batches, []),
            issue_lookup: Keyword.get(opts, :issue_lookup, %{}),
            run_results: Keyword.get(opts, :run_results, []),
            updates: [],
            comments: [],
            runs: [],
            fetches: [],
            candidate_polls: 0,
            test_pid: Keyword.fetch!(opts, :test_pid)
          }
        end,
        name: __MODULE__
      )
    end

    def next_candidates do
      Agent.get_and_update(__MODULE__, fn state ->
        case state.candidate_batches do
          [batch | rest] ->
            {batch,
             %{state | candidate_batches: rest, candidate_polls: state.candidate_polls + 1}}

          [] ->
            {[], %{state | candidate_polls: state.candidate_polls + 1}}
        end
      end)
    end

    def next_issue(identifier) do
      Agent.get_and_update(__MODULE__, fn state ->
        issue = Map.get(state.issue_lookup, identifier)
        {issue, %{state | fetches: [identifier | state.fetches]}}
      end)
    end

    def fetches do
      Agent.get(__MODULE__, &Enum.reverse(&1.fetches))
    end

    def candidate_polls do
      Agent.get(__MODULE__, & &1.candidate_polls)
    end

    def next_run_result(issue_identifier) do
      Agent.get_and_update(__MODULE__, fn state ->
        send(state.test_pid, {:agent_run, issue_identifier})

        case state.run_results do
          [result | rest] ->
            {result, %{state | run_results: rest, runs: [issue_identifier | state.runs]}}

          [] ->
            default = %{status: :success, events: [], error: nil}
            {default, %{state | runs: [issue_identifier | state.runs]}}
        end
      end)
    end

    def record_update(issue, payload) do
      Agent.update(__MODULE__, fn state ->
        %{state | updates: [%{issue: issue, payload: payload} | state.updates]}
      end)
    end

    def record_comment(issue_identifier, body) do
      Agent.update(__MODULE__, fn state ->
        %{state | comments: [%{issue_identifier: issue_identifier, body: body} | state.comments]}
      end)
    end

    def updates do
      Agent.get(__MODULE__, &Enum.reverse(&1.updates))
    end

    def comments do
      Agent.get(__MODULE__, &Enum.reverse(&1.comments))
    end

    def runs do
      Agent.get(__MODULE__, &Enum.reverse(&1.runs))
    end
  end

  defmodule MockTracker do
    @behaviour SymphonyEx.Tracker

    def fetch_candidate_issues(_opts), do: {:ok, Control.next_candidates()}
    def fetch_issue_by_identifier(identifier, _opts), do: {:ok, Control.next_issue(identifier)}
    def fetch_issue_comments(_issue_id, _opts), do: {:ok, []}

    def create_comment(issue_id, body, _opts) do
      Control.record_comment(issue_id, body)
      {:ok, %{}}
    end

    def update_issue_state(_issue, _state_name, _opts), do: {:ok, %{}}
    def update_issue_description(_issue_id, _description, _opts), do: {:ok, %{}}

    def write_run_record(issue, payload, _opts) do
      Control.record_update(issue, payload)
      {:ok, %{}}
    end
  end

  defmodule MockWorkspace do
    def prepare(issue, _opts), do: {:ok, %{path: "/tmp/#{issue.identifier}", reason: :fresh}}
    def create(issue, _opts), do: {:ok, "/tmp/#{issue.identifier}"}
    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok
    def cleanup_inactive_worktrees(_opts), do: :ok
  end

  defmodule CleanupWorkspace do
    def prepare(issue, _opts), do: {:ok, %{path: "/tmp/#{issue.identifier}", reason: :fresh}}
    def create(issue, _opts), do: {:ok, "/tmp/#{issue.identifier}"}
    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok

    def cleanup_inactive_worktrees(opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:cleanup_called, Keyword.get(opts, :active_issue_identifiers, [])}
      )

      :ok
    end
  end

  defmodule BeforeHookFailWorkspace do
    def prepare(issue, _opts), do: {:ok, %{path: "/tmp/#{issue.identifier}", reason: :fresh}}
    def create(issue, _opts), do: {:ok, "/tmp/#{issue.identifier}"}
    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(:before_run, _path, _opts, _issue), do: {:error, :before_boom}
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok
  end

  defmodule AfterHookFailWorkspace do
    def prepare(issue, _opts), do: {:ok, %{path: "/tmp/#{issue.identifier}", reason: :fresh}}
    def create(issue, _opts), do: {:ok, "/tmp/#{issue.identifier}"}
    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(:after_run, _path, _opts, _issue), do: {:error, :after_boom}
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok
  end

  defmodule MockAgentRunner do
    def run(issue, _opts), do: Control.next_run_result(issue.identifier)
  end

  defmodule RecoveringWorkspace do
    def prepare(issue, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:workspace_prepare, issue.identifier})

      {:ok,
       %{
         path: "/tmp/#{issue.identifier}",
         reason: {:recover, %{thread_id: "thread-1", recovery_count: 1}}
       }}
    end

    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok
  end

  setup do
    start_supervised!({Task.Supervisor, name: SymphonyEx.TestAgentWorkers})

    if Process.whereis(SymphonyEx.Observability) == nil do
      start_supervised!({SymphonyEx.Observability, name: SymphonyEx.Observability})
    end

    SymphonyEx.Observability.reset()
    :ok
  end

  test "backs off candidate polling when GitHub rate limits are low" do
    SymphonyEx.Observability.record_rate_limit(:github, %{
      remaining: 10,
      limit: 5000,
      reset: "1775174400"
    })

    start_supervised!({Control, test_pid: self(), candidate_batches: [[], []]})

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn -> Control.candidate_polls() == 1 end)

    snapshot = Orchestrator.snapshot(orchestrator)
    assert snapshot.candidate_poll_interval_ms == 120_000

    send(orchestrator, :tick)
    Process.sleep(50)

    assert Control.candidate_polls() == 1
  end

  test "suppresses dashboard broadcasts on no-op ticks" do
    if Process.whereis(SymphonyEx.PubSub) == nil do
      start_supervised!({Phoenix.PubSub, name: SymphonyEx.PubSub})
    end

    Phoenix.PubSub.subscribe(SymphonyEx.PubSub, SymphonyEx.Dashboard.topic())
    start_supervised!({Control, test_pid: self(), candidate_batches: [[], [], []]})

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 60_000,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    assert_receive {:runtime_snapshot_updated, initial_snapshot}
    assert initial_snapshot.summary.running_count == 0
    assert initial_snapshot.summary.completed_count == 0

    refute_receive {:runtime_snapshot_updated, _}, 75

    send(orchestrator, :tick)

    refute_receive {:runtime_snapshot_updated, _}, 75
  end

  test "runs inactive worktree cleanup during ticks" do
    start_supervised!({Control, test_pid: self(), candidate_batches: [[]]})

    start_supervised!(
      {Orchestrator,
       tracker: MockTracker,
       workspace: CleanupWorkspace,
       agent_runner: MockAgentRunner,
       tracker_opts: [],
       workspace_opts: [test_pid: self()],
       workflow_path: "/tmp/WORKFLOW.md",
       codex: [],
       poll_interval_ms: 60_000,
       retry_backoff_ms: 10,
       max_retry_backoff_ms: 10,
       max_concurrent: 1,
       task_supervisor: SymphonyEx.TestAgentWorkers}
    )

    assert_receive {:cleanup_called, []}, 500
  end

  test "posts a completion summary comment after successful runs" do
    issue = issue_fixture("SUMMARY-1")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [
         %{
           status: :success,
           events: [],
           error: nil,
           last_message: "- what changed\n- files touched\n- validation performed"
         }
       ]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(snapshot.completed) == 1
    end)

    assert Enum.any?(Control.comments(), fn %{issue_identifier: identifier, body: body} ->
             identifier == "SUMMARY-1" and body =~ "## Symphony 작업 요약" and
               body =~ "files touched"
           end)
  end

  test "posts a completion summary comment from nested event content when last_message is nil" do
    issue = issue_fixture("SUMMARY-2")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [
         %{
           status: :success,
           error: nil,
           last_message: nil,
           events: [
             %Events{
               event: :notification,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
               raw_method: "notification",
               message: nil,
               params: %{
                 "data" => %{
                   "content" =>
                     "- updated verse card layouts\n- synced branch with PR #19\n- verified remote push"
                 }
               }
             }
           ]
         }
       ]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(snapshot.completed) == 1
    end)

    assert Enum.any?(Control.comments(), fn %{issue_identifier: identifier, body: body} ->
             identifier == "SUMMARY-2" and body =~ "## Symphony 작업 요약" and
               body =~ "verified remote push"
           end)
  end

  test "prefers the latest summary-bearing event over earlier prompt-like payloads" do
    issue = issue_fixture("SUMMARY-3")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [
         %{
           status: :success,
           error: nil,
           last_message: nil,
           events: [
             %Events{
               event: :turn_completed,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
               raw_method: "turn.completed",
               message: nil,
               params: %{
                 "input" => [
                   %{
                     "type" => "text",
                     "text" =>
                       "You are an unattended coding agent working on GitHub issue 29\n\n## Operating Rules"
                   }
                 ]
               }
             },
             %Events{
               event: :notification,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
               raw_method: "notification",
               message: nil,
               params: %{
                 "data" => %{
                   "content" => "- what changed\n- files touched\n- validation performed"
                 }
               }
             }
           ]
         }
       ]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(snapshot.completed) == 1
    end)

    assert Enum.any?(Control.comments(), fn %{issue_identifier: identifier, body: body} ->
             identifier == "SUMMARY-3" and body =~ "validation performed" and
               body =~ "files touched" and
               not String.contains?(body, "You are an unattended coding agent") and
               not String.contains?(body, "## Operating Rules")
           end)
  end

  test "skips summary comments when only request prompt payload is available" do
    issue = issue_fixture("SUMMARY-4")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [
         %{
           status: :success,
           error: nil,
           last_message: nil,
           events: [
             %Events{
               event: :turn_completed,
               timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
               raw_method: "turn.completed",
               message: nil,
               params: %{
                 "input" => [
                   %{
                     "type" => "text",
                     "text" =>
                       "You are an unattended coding agent working on GitHub issue 29\n\n## Final Response Format"
                   }
                 ]
               }
             }
           ]
         }
       ]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(snapshot.completed) == 1
    end)

    refute Enum.any?(Control.comments(), fn %{issue_identifier: identifier, body: body} ->
             identifier == "SUMMARY-4" and body =~ "## Symphony 작업 요약"
           end)
  end

  test "before_run hook failure blocks execution before the agent starts" do
    issue = issue_fixture("SYM-HOOK-1")

    start_supervised!({Control, test_pid: self(), candidate_batches: [[issue], []]})

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: BeforeHookFailWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      length(snapshot.completed) == 1
    end)

    snapshot = Orchestrator.snapshot(orchestrator)
    assert snapshot.retry_queue != []

    assert Control.runs() == []

    assert Enum.any?(Control.updates(), fn %{issue: updated_issue, payload: payload} ->
             updated_issue.identifier == "SYM-HOOK-1" and
               payload.status == :retry_queued and
               String.contains?(
                 to_string(Map.get(payload, :details, "")),
                 "before_run_hook_failed"
               )
           end)
  end

  test "after_run hook failure is surfaced in completion metadata" do
    issue = issue_fixture("SYM-HOOK-2")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [%{status: :success, events: [], error: nil}]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: AfterHookFailWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      length(snapshot.completed) == 1
    end)

    snapshot = Orchestrator.snapshot(orchestrator)
    assert snapshot.retry_queue != []

    assert Enum.any?(Control.runs(), &(&1 == "SYM-HOOK-2"))

    assert Enum.any?(Control.updates(), fn %{issue: updated_issue, payload: payload} ->
             updated_issue.identifier == "SYM-HOOK-2" and
               payload.status == :retry_queued and
               String.contains?(
                 to_string(Map.get(payload, :details, "")),
                 "after_run_hook_failed"
               )
           end)
  end

  test "retries failed runs with backoff and eventually releases success" do
    issue = issue_fixture("SYM-101")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [
         %{status: :failed, events: [], error: "boom"},
         %{status: :success, events: [], error: nil}
       ]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_retries: 2,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)

      map_size(snapshot.running) == 0 and map_size(snapshot.retry_queue) == 0 and
        Control.runs() == ["SYM-101", "SYM-101"]
    end)

    payloads = Control.updates() |> Enum.map(& &1.payload)

    assert Enum.map(payloads, &{&1.status, &1.attempt, Map.get(&1, :result)}) == [
             {:claimed, 0, nil},
             {:running, 0, nil},
             {:retry_queued, 1, nil},
             {:claimed, 1, nil},
             {:running, 1, nil},
             {:released, 1, :success}
           ]

    assert Enum.at(payloads, 2).backoff_ms == 10
  end

  test "releases failed runs after max retries are exhausted" do
    issue = issue_fixture("SYM-202")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue], []],
       run_results: [
         %{status: :failed, events: [], error: "boom-1"},
         %{status: :failed, events: [], error: "boom-2"}
       ]}
    )

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: MockTracker,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_retries: 1,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.TestAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)

      map_size(snapshot.running) == 0 and map_size(snapshot.retry_queue) == 0 and
        Control.runs() == ["SYM-202", "SYM-202"]
    end)

    payloads = Control.updates() |> Enum.map(& &1.payload)

    assert Enum.map(payloads, &{&1.status, &1.attempt, Map.get(&1, :result)}) == [
             {:claimed, 0, nil},
             {:running, 0, nil},
             {:retry_queued, 1, nil},
             {:claimed, 1, nil},
             {:running, 1, nil},
             {:released, 1, :failed}
           ]

    assert Enum.at(payloads, 2).backoff_ms == 10
  end

  test "dispatches an explicit issue via fetch_issue_by_identifier before candidate polling" do
    issue = issue_fixture("#401")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[]],
       issue_lookup: %{"#401" => issue},
       run_results: [%{status: :success, events: [], error: nil}]}
    )

    orchestrator = start_orchestrator(issue_identifier: "#401")

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 1
    end)

    assert Control.fetches() == ["#401"]
    assert Control.runs() == ["#401"]

    payloads = Control.updates() |> Enum.map(& &1.payload)
    assert Enum.map(payloads, & &1.status) == [:claimed, :running, :released]
  end

  test "runs workspace recovery preflight before agent execution" do
    issue = issue_fixture("PRE-1")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue]],
       run_results: [%{status: :success, events: [], error: nil}]}
    )

    orchestrator =
      start_orchestrator(
        workspace: RecoveringWorkspace,
        workspace_opts: [test_pid: self()]
      )

    assert_receive {:workspace_prepare, "PRE-1"}, 500

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 1
    end)

    assert Control.runs() == ["PRE-1"]
  end

  test "prioritizes higher-priority eligible candidates and skips blocked ones" do
    low = issue_fixture("2", priority: 1)
    high = issue_fixture("1", priority: 10, labels: ["severity:critical"])
    blocked = issue_fixture("3", priority: 100, labels: ["blocked"])

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[low, blocked, high]],
       run_results: [%{status: :success, events: [], error: nil}]}
    )

    orchestrator = start_orchestrator(max_concurrent: 1)

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 1
    end)

    assert Control.runs() == ["1"]

    snapshot = Orchestrator.snapshot(orchestrator)
    assert snapshot.blocked_labels |> MapSet.member?("blocked")
  end

  test "writes GitHub-visible gating reason for blocked issues and dedupes repeated skips" do
    blocked = issue_fixture("BLOCKED-1", labels: ["blocked"])

    start_supervised!({Control, test_pid: self(), candidate_batches: [[blocked], [blocked], []]})

    orchestrator = start_orchestrator(max_concurrent: 1)

    Process.sleep(100)
    send(orchestrator, :tick)
    Process.sleep(100)

    gated_updates =
      Control.updates()
      |> Enum.filter(fn %{issue: issue, payload: payload} ->
        issue.identifier == "BLOCKED-1" and payload.status == :gated
      end)

    assert length(gated_updates) == 1

    assert [%{payload: payload}] = gated_updates
    assert payload.gating_reason == :human_blocked
    assert payload.attempt == 0
  end

  test "respects per-class concurrency limits when dispatching in parallel" do
    code_a = issue_fixture("10", labels: ["bug"])
    code_b = issue_fixture("11", labels: ["feature"])
    docs = issue_fixture("12", labels: ["docs"])

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[code_a, code_b, docs]],
       run_results: [
         %{status: :success, events: [], error: nil},
         %{status: :success, events: [], error: nil}
       ]}
    )

    orchestrator =
      start_orchestrator(
        max_concurrent: 3,
        concurrency_limits: %{code: 1, docs: 2, default: 1}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 2
    end)

    assert Control.runs() == ["10", "12"]

    snapshot = Orchestrator.snapshot(orchestrator)
    assert snapshot.concurrency_limits[:code] == 1
    assert snapshot.concurrency_limits[:docs] == 2
  end

  test "ignores unknown concurrency limit classes instead of atomizing them" do
    start_supervised!({Control, test_pid: self(), candidate_batches: [[]]})

    orchestrator =
      start_orchestrator(concurrency_limits: %{"code" => 1, "dangerously-new-class" => 9})

    snapshot = Orchestrator.snapshot(orchestrator)

    assert snapshot.concurrency_limits[:code] == 1
    refute Map.has_key?(snapshot.concurrency_limits, :"dangerously-new-class")
  end

  test "applies starvation bonus so repeatedly deferred work eventually runs first" do
    low = issue_fixture("20", priority: 0, labels: ["bug"])
    high = issue_fixture("21", priority: 60, labels: ["bug"])

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[low, high], [low], []],
       run_results: [
         %{status: :success, events: [], error: nil},
         %{status: :success, events: [], error: nil}
       ]}
    )

    orchestrator =
      start_orchestrator(
        max_concurrent: 1,
        poll_interval_ms: 25,
        concurrency_limits: %{code: 1, docs: 1, default: 1},
        tracker_opts: [starvation_bonus_step: 35, starvation_bonus_cap: 120]
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 2
    end)

    assert Control.runs() == ["21", "20"]

    snapshot = Orchestrator.snapshot(orchestrator)
    assert snapshot.deferral_counts == %{}
  end

  test "serializes candidates that share a conflict boundary declared in issue body hints" do
    issue_a = issue_fixture("18", labels: ["bug"], conflict_hints: ["service:api"])
    issue_b = issue_fixture("19", labels: ["feature"], conflict_hints: ["service:api"])
    issue_c = issue_fixture("17", labels: ["docs"], conflict_hints: ["service:docs"])

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue_a, issue_b, issue_c]],
       run_results: [
         %{status: :success, events: [], error: nil},
         %{status: :success, events: [], error: nil}
       ]}
    )

    orchestrator =
      start_orchestrator(
        max_concurrent: 3,
        concurrency_limits: %{code: 2, docs: 2, default: 2}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 2
    end)

    assert Control.runs() == ["18", "17"]
  end

  test "writes GitHub-visible gating reason for serialized conflicts" do
    issue_a = issue_fixture("30", labels: ["bug"], conflict_hints: ["service:api"])
    issue_b = issue_fixture("31", labels: ["feature"], conflict_hints: ["service:api"])

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue_a, issue_b]],
       run_results: [%{status: :success, events: [], error: nil}]}
    )

    orchestrator =
      start_orchestrator(
        max_concurrent: 2,
        concurrency_limits: %{code: 2, docs: 1, default: 1}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 1
    end)

    assert Control.runs() == ["30"]

    assert Enum.any?(Control.updates(), fn %{issue: issue, payload: payload} ->
             issue.identifier == "31" and payload.status == :gated and
               payload.gating_reason == :serialized_conflict
           end)
  end

  test "serializes candidates that share an explicit conflict boundary label" do
    issue_a = issue_fixture("20", labels: ["bug", "service:api"])
    issue_b = issue_fixture("21", labels: ["feature", "service:api"])
    issue_c = issue_fixture("22", labels: ["docs", "service:docs"])

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue_a, issue_b, issue_c]],
       run_results: [
         %{status: :success, events: [], error: nil},
         %{status: :success, events: [], error: nil}
       ]}
    )

    orchestrator =
      start_orchestrator(
        max_concurrent: 3,
        concurrency_limits: %{code: 2, docs: 2, default: 2}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 2
    end)

    assert Control.runs() == ["20", "22"]

    snapshot = Orchestrator.snapshot(orchestrator)

    assert snapshot.serialization_label_prefixes == [
             "scope:",
             "service:",
             "path:",
             "package:",
             "release:"
           ]
  end

  test "deduplicates identical persisted run-state payloads" do
    issue = issue_fixture("IDEMP-1")

    start_supervised!(
      {Control,
       test_pid: self(),
       candidate_batches: [[issue]],
       run_results: [%{status: :success, events: [], error: nil}]}
    )

    orchestrator = start_orchestrator()

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      map_size(snapshot.running) == 0 and length(Control.runs()) == 1
    end)

    before_count = length(Control.updates())

    send(orchestrator, :tick)
    Process.sleep(50)

    after_count = length(Control.updates())
    assert before_count == 3
    assert after_count == before_count
  end

  describe "run-state sequence (lifecycle semantics)" do
    test "success path emits claimed → running → released(success)" do
      issue = issue_fixture("LC-1")

      start_supervised!(
        {Control,
         test_pid: self(),
         candidate_batches: [[issue]],
         run_results: [%{status: :success, events: [], error: nil}]}
      )

      orchestrator = start_orchestrator()

      wait_until(fn ->
        snapshot = Orchestrator.snapshot(orchestrator)
        map_size(snapshot.running) == 0 and length(Control.runs()) == 1
      end)

      states = Control.updates() |> Enum.map(& &1.payload) |> Enum.map(& &1[:status])
      assert states == [:claimed, :running, :released]

      final = Control.updates() |> List.last()
      assert final.payload[:result] == :success
    end

    test "retry then success emits claimed → running → retry_queued → claimed → running → released(success)" do
      issue = issue_fixture("LC-2")

      start_supervised!(
        {Control,
         test_pid: self(),
         candidate_batches: [[issue]],
         run_results: [
           %{status: :failed, events: [], error: "boom"},
           %{status: :success, events: [], error: nil}
         ]}
      )

      orchestrator = start_orchestrator(max_retries: 2)

      wait_until(fn ->
        snapshot = Orchestrator.snapshot(orchestrator)

        map_size(snapshot.running) == 0 and map_size(snapshot.retry_queue) == 0 and
          length(Control.runs()) == 2
      end)

      states = Control.updates() |> Enum.map(& &1.payload) |> Enum.map(& &1[:status])
      assert states == [:claimed, :running, :retry_queued, :claimed, :running, :released]

      final = Control.updates() |> List.last()
      assert final.payload[:result] == :success
    end

    test "exhausted retries emits claimed → running → retry_queued → claimed → running → released(failed)" do
      issue = issue_fixture("LC-3")

      start_supervised!(
        {Control,
         test_pid: self(),
         candidate_batches: [[issue]],
         run_results: [
           %{status: :failed, events: [], error: "boom-1"},
           %{status: :failed, events: [], error: "boom-2"}
         ]}
      )

      orchestrator = start_orchestrator(max_retries: 1)

      wait_until(fn ->
        snapshot = Orchestrator.snapshot(orchestrator)

        map_size(snapshot.running) == 0 and map_size(snapshot.retry_queue) == 0 and
          length(Control.runs()) == 2
      end)

      states = Control.updates() |> Enum.map(& &1.payload) |> Enum.map(& &1[:status])
      assert states == [:claimed, :running, :retry_queued, :claimed, :running, :released]

      final = Control.updates() |> List.last()
      assert final.payload[:result] == :failed
    end

    test "lifecycle falls back from tracker_opts when no top-level lifecycle opt is passed" do
      alias SymphonyEx.Orchestrator.Lifecycle

      tracker_lifecycle =
        Lifecycle.new(
          project_status_mapping: %{
            {:claimed, :any} => "Selected",
            {:running, :any} => "Selected",
            {:retry_queued, :any} => "Queued",
            {:released, :success} => "Delivered",
            {:released, :any} => "Queued"
          }
        )

      issue = issue_fixture("LC-5")

      start_supervised!(
        {Control,
         test_pid: self(),
         candidate_batches: [[issue]],
         run_results: [%{status: :success, events: [], error: nil}]}
      )

      orchestrator = start_orchestrator(tracker_opts: [lifecycle: tracker_lifecycle])

      wait_until(fn ->
        snapshot = Orchestrator.snapshot(orchestrator)
        map_size(snapshot.running) == 0 and length(Control.runs()) == 1
      end)

      snapshot = Orchestrator.snapshot(orchestrator)
      assert snapshot.lifecycle == tracker_lifecycle
      assert Keyword.get(snapshot.tracker_opts, :lifecycle) == tracker_lifecycle
    end

    test "lifecycle config is forwarded to tracker_opts" do
      alias SymphonyEx.Orchestrator.Lifecycle

      custom_lifecycle =
        Lifecycle.new(
          project_status_mapping: %{
            {:claimed, :any} => "Working",
            {:running, :any} => "Working",
            {:retry_queued, :any} => "Backlog",
            {:released, :success} => "Shipped",
            {:released, :any} => "Backlog"
          }
        )

      issue = issue_fixture("LC-4")

      start_supervised!(
        {Control,
         test_pid: self(),
         candidate_batches: [[issue]],
         run_results: [%{status: :success, events: [], error: nil}]}
      )

      orchestrator = start_orchestrator(lifecycle: custom_lifecycle)

      wait_until(fn ->
        snapshot = Orchestrator.snapshot(orchestrator)
        map_size(snapshot.running) == 0 and length(Control.runs()) == 1
      end)

      snapshot = Orchestrator.snapshot(orchestrator)
      assert snapshot.lifecycle == custom_lifecycle
      assert Keyword.get(snapshot.tracker_opts, :lifecycle) == custom_lifecycle
    end
  end

  defp start_orchestrator(extra_opts \\ []) do
    opts =
      Keyword.merge(
        [
          tracker: MockTracker,
          workspace: MockWorkspace,
          agent_runner: MockAgentRunner,
          tracker_opts: [],
          workspace_opts: [],
          workflow_path: "/tmp/WORKFLOW.md",
          codex: [],
          poll_interval_ms: 25,
          retry_backoff_ms: 10,
          max_retry_backoff_ms: 10,
          max_retries: 2,
          max_concurrent: 1,
          task_supervisor: SymphonyEx.TestAgentWorkers
        ],
        extra_opts
      )

    start_supervised!({Orchestrator, opts})
  end

  defp issue_fixture(identifier, attrs \\ []) do
    struct!(
      Issue,
      [
        id: "issue-#{identifier}",
        identifier: identifier,
        title: "Test issue #{identifier}",
        description: "",
        state: "Todo",
        priority: 0,
        labels: []
      ] ++ attrs
    )
  end

  defp wait_until(fun, attempts \\ 40)
  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end
end
