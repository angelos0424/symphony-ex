defmodule SymphonyEx.RuntimeSnapshotTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.{Domain.Issue, Observability}
  alias SymphonyEx.RunEventLogger
  alias SymphonyEx.RuntimeSnapshot
  alias SymphonyEx.SessionStore

  test "normalizes running, retry, and completed entries for dashboard/api consumers" do
    Observability.reset()
    Observability.record_rate_limit(:github, %{remaining: 4321, limit: 5000, reset: "1775174400"})

    Observability.record_write_back_stage("SYM-1", :github, :essential, :success, %{
      status: :running
    })

    Observability.record_write_back_stage("SYM-0", :github, :optional, :partial, %{
      failed_stage: :label_sync_failed,
      reason: "labels_down"
    })

    running_issue = issue_fixture("SYM-1", labels: ["bug"], assignees: ["n100"])
    retry_issue = issue_fixture("SYM-2", labels: ["docs"], conflict_hints: ["service:docs"])
    completed_issue = issue_fixture("SYM-0", labels: ["feature"])

    running_workspace = temp_workspace("runtime-snapshot-running")
    completed_workspace = temp_workspace("runtime-snapshot-completed")

    write_events!(running_workspace, [
      %{"event" => "run_started", "timestamp" => "2026-03-30T00:00:00Z", "message" => "started"}
    ])

    write_events!(completed_workspace, [
      %{"event" => "run_started", "timestamp" => "2026-03-29T23:58:30Z", "message" => "started"},
      %{
        "event" => "turn_completed",
        "timestamp" => "2026-03-29T23:59:30Z",
        "message" => "done",
        "raw_method" => "turn.completed"
      },
      %{
        "event" => "run_finished",
        "timestamp" => "2026-03-30T00:00:00Z",
        "message" => "success",
        "status" => "success"
      }
    ])

    SessionStore.save(completed_workspace, %{
      thread_id: "thread-0",
      turn_id: "turn-0",
      session_id: "session-0",
      issue_identifier: "SYM-0",
      turns_executed: 3,
      recovery_count: 1,
      last_event: "turn_completed",
      phase: :completed,
      capability_profile: %{supports_thread_reuse: true}
    })

    debug_dir = Path.join([completed_workspace, ".symphony", "debug"])
    File.mkdir_p!(debug_dir)
    File.write!(Path.join(debug_dir, "stderr.log"), "warning\n")

    now_mono_ms = System.monotonic_time(:millisecond)

    state = %{
      explicit_issue_identifier: "SYM-9",
      completed_issue_identifiers: MapSet.new(["SYM-0"]),
      completed: [
        %{
          issue: completed_issue,
          attempt: 2,
          result: :success,
          completed_at: ~U[2026-03-30 00:00:00Z],
          started_at: ~U[2026-03-29 23:58:30Z],
          elapsed_ms: 90_000,
          workspace_path: completed_workspace,
          thread_id: "thread-0",
          turn_id: "turn-0",
          session_id: "session-0",
          recovery_count: 1,
          last_event: "turn_completed",
          last_message: "done",
          error: nil,
          error_category: nil
        }
      ],
      workflow_path: "/tmp/WORKFLOW.md",
      poll_interval_ms: 2_000,
      max_concurrent: 3,
      max_retries: 2,
      retry_backoff_ms: 5_000,
      max_retry_backoff_ms: 60_000,
      blocked_labels: MapSet.new(["blocked", "needs-human"]),
      concurrency_limits: %{code: 1, docs: 2, default: 1},
      serialization_label_prefixes: ["scope:", "service:"],
      running: %{
        running_issue.identifier => %{
          issue: running_issue,
          task: %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :test, 0}},
          workspace_path: running_workspace,
          state: :running,
          attempt: 1,
          concurrency_class: :code,
          conflict_keys: MapSet.new(["service:api"]),
          started_at: ~U[2026-03-30 00:00:00Z],
          started_at_ms: System.system_time(:millisecond) - 15_000,
          started_at_mono_ms: now_mono_ms - 15_000
        }
      },
      retry_queue: %{
        retry_issue.identifier => %{
          issue: retry_issue,
          attempt: 2,
          due_at_ms: now_mono_ms + 45_000,
          queued_at: ~U[2026-03-30 00:01:00Z],
          queued_at_ms: System.system_time(:millisecond) - 10_000,
          queued_at_mono_ms: now_mono_ms - 10_000,
          backoff_ms: 45_000,
          last_result: %{
            status: :failed,
            error: "boom",
            error_category: "turn_failed",
            last_event: "turn_failed",
            last_message: "tool exploded",
            elapsed_ms: 22_000
          },
          concurrency_class: :docs,
          conflict_keys: MapSet.new(["service:docs"])
        }
      }
    }

    snapshot = RuntimeSnapshot.from_state(state)

    assert snapshot.summary == %{
             running_count: 1,
             retry_queue_count: 1,
             completed_count: 1,
             success_count: 1,
             failed_count: 0,
             cancelled_count: 0,
             success_rate: 100.0,
             average_runtime_ms: 90_000.0,
             available_slots: 2,
             max_concurrent: 3,
             write_back_alert_count: 1,
             rate_limits: %{
               github: %{
                 remaining: 4321,
                 limit: 5000,
                 reset_at: "2026-04-03T00:00:00Z",
                 retry_after: nil,
                 captured_at: snapshot.summary.rate_limits.github.captured_at
               }
             }
           }

    assert snapshot.settings == %{
             poll_interval_ms: 2_000,
             candidate_poll_interval_ms: 2_000,
             candidate_poll_backoff_until: nil,
             max_concurrent: 3,
             max_retries: 2,
             retry_backoff_ms: 5_000,
             max_retry_backoff_ms: 60_000,
             concurrency_limits: %{"code" => 1, "default" => 1, "docs" => 2},
             blocked_labels: ["blocked", "needs-human"],
             serialization_label_prefixes: ["scope:", "service:"],
             explicit_issue_identifier: "SYM-9",
             workflow_path: "/tmp/WORKFLOW.md"
           }

    assert Enum.map(snapshot.write_back_stages.recent, & &1.stage) == ["optional", "essential"]
    assert snapshot.write_back_stages.alert_count == 1

    assert [running] = snapshot.running
    assert running.issue.identifier == "SYM-1"
    assert running.workspace_path == running_workspace
    assert running.concurrency_class == :code
    assert running.conflict_keys == ["service:api"]
    assert running.started_at == "2026-03-30T00:00:00Z"
    assert is_integer(running.elapsed_ms)
    assert running.elapsed_ms >= 14_000
    assert running.log_excerpt.exists == true
    assert running.log_excerpt.event_count == 1

    assert [retry] = snapshot.retry_queue
    assert retry.issue.identifier == "SYM-2"
    assert retry.attempt == 2
    assert retry.concurrency_class == :docs
    assert retry.conflict_keys == ["service:docs"]
    assert retry.backoff_ms == 45_000
    assert retry.last_result.status == :failed
    assert retry.last_result.error == "boom"
    assert is_binary(retry.due_at)
    assert is_integer(retry.due_in_ms)
    assert retry.log_excerpt.exists == false

    assert [completed] = snapshot.completed
    assert completed.attempt == 2
    assert completed.result == :success
    assert completed.completed_at == "2026-03-30T00:00:00Z"
    assert completed.started_at == "2026-03-29T23:58:30Z"
    assert completed.elapsed_ms == 90_000
    assert completed.thread_id == "thread-0"
    assert completed.session_id == "session-0"
    assert completed.last_event == "turn_completed"
    assert completed.issue.identifier == "SYM-0"
    assert completed.issue.title == "Test issue SYM-0"
    assert completed.issue.labels == ["feature"]
    assert completed.log_excerpt.exists == true
    assert completed.log_excerpt.event_count == 3

    assert Enum.map(completed.log_excerpt.recent_events, & &1.event) == [
             "run_started",
             "turn_completed",
             "run_finished"
           ]

    assert snapshot.completed_issue_identifiers == ["SYM-0"]

    detail = RuntimeSnapshot.run_detail(snapshot, "SYM-0")
    assert detail.queue == :completed
    assert detail.paths.workspace == completed_workspace
    assert detail.paths.events == RunEventLogger.events_path(completed_workspace)
    assert detail.paths.session == SessionStore.session_path(completed_workspace)
    assert detail.session_excerpt.exists == true
    assert detail.session_excerpt.data.phase == :completed
    assert detail.session_excerpt.data.turns_executed == 3
    assert detail.debug_excerpt.exists == true
    assert detail.debug_excerpt.files == ["stderr.log"]
    assert detail.log_timeline.event_count == 3
    assert Enum.map(detail.write_back_stages, & &1.stage) == ["optional"]

    assert Enum.map(detail.log_timeline.recent_events, & &1.event) == [
             "run_started",
             "turn_completed",
             "run_finished"
           ]

    assert RuntimeSnapshot.find_run(snapshot, "SYM-1").queue == :running
    assert RuntimeSnapshot.run_detail(snapshot, "SYM-404") == nil
  end

  test "observer fingerprint ignores no-op time passage but changes on observer-visible state" do
    Observability.reset()
    issue = issue_fixture("SYM-OBS")
    now_mono_ms = System.monotonic_time(:millisecond)

    base_state = %{
      explicit_issue_identifier: nil,
      completed_issue_identifiers: MapSet.new(),
      completed: [],
      workflow_path: "/tmp/WORKFLOW.md",
      poll_interval_ms: 2_000,
      max_concurrent: 1,
      max_retries: 2,
      retry_backoff_ms: 5_000,
      max_retry_backoff_ms: 60_000,
      blocked_labels: MapSet.new(["blocked"]),
      concurrency_limits: %{code: 1, default: 1},
      serialization_label_prefixes: ["service:"],
      running: %{
        issue.identifier => %{
          issue: issue,
          task: %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :test, 0}},
          workspace_path: "/tmp/#{issue.identifier}",
          state: :running,
          attempt: 1,
          concurrency_class: :code,
          conflict_keys: MapSet.new(["service:api"]),
          started_at: ~U[2026-03-30 00:00:00Z],
          started_at_ms: System.system_time(:millisecond) - 15_000,
          started_at_mono_ms: now_mono_ms - 15_000
        }
      },
      retry_queue: %{}
    }

    fingerprint = RuntimeSnapshot.observer_fingerprint(base_state)
    assert RuntimeSnapshot.observer_fingerprint(base_state) == fingerprint

    changed_state =
      put_in(
        base_state,
        [:running, issue.identifier, :attempt],
        2
      )

    refute RuntimeSnapshot.observer_fingerprint(changed_state) == fingerprint
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

  defp temp_workspace(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  defp write_events!(workspace_path, entries) do
    body = Enum.map_join(entries, "\n", &Jason.encode!/1) <> "\n"
    File.write!(RunEventLogger.events_path(workspace_path), body)
  end
end
