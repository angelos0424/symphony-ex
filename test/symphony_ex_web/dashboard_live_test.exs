defmodule SymphonyExWeb.DashboardLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias SymphonyEx.{Dashboard, Observability}
  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.RunEventLogger
  alias SymphonyEx.SessionStore
  alias SymphonyExWeb.Endpoint

  @endpoint Endpoint

  defmodule SnapshotServer do
    use GenServer

    def start_link(state) do
      GenServer.start_link(__MODULE__, state)
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:snapshot, _from, state), do: {:reply, state, state}
  end

  setup_all do
    previous = Application.get_env(:symphony_ex, Endpoint)

    Application.put_env(:symphony_ex, Endpoint,
      adapter: Bandit.PhoenixAdapter,
      render_errors: [formats: [html: SymphonyExWeb.ErrorHTML, json: SymphonyExWeb.ErrorJSON]],
      pubsub_server: SymphonyEx.PubSub,
      live_view: [signing_salt: "dashboard-tests"],
      secret_key_base: String.duplicate("a", 64),
      check_origin: false,
      server: false
    )

    start_supervised!({Phoenix.PubSub, name: SymphonyEx.PubSub})
    start_supervised!(Endpoint)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:symphony_ex, Endpoint)
      else
        Application.put_env(:symphony_ex, Endpoint, previous)
      end
    end)

    :ok
  end

  setup do
    Observability.reset()
    Observability.record_rate_limit(:github, %{remaining: 4321, limit: 5000, reset: "1775174400"})

    Observability.record_write_back_stage("SYM-1", :github, :essential, :success, %{
      status: :running
    })

    Observability.record_write_back_stage("SYM-0", :github, :optional, :partial, %{
      failed_stage: :label_sync_failed,
      reason: "labels_down"
    })

    now_mono_ms = System.monotonic_time(:millisecond)
    completed_workspace = temp_workspace("dashboard-live-completed")

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

    state = %{
      explicit_issue_identifier: "SYM-9",
      completed_issue_identifiers: MapSet.new(["SYM-0", "SYM-3"]),
      completed: [
        %{
          issue: issue_fixture("SYM-0", labels: ["feature"], priority: 1, assignees: ["alice"]),
          attempt: 2,
          result: :success,
          completed_at: DateTime.add(DateTime.utc_now(), -3600, :second),
          started_at: DateTime.add(DateTime.utc_now(), -5400, :second),
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
        },
        %{
          issue: issue_fixture("SYM-3", labels: ["ops"], priority: 2, assignees: ["bob"]),
          attempt: 1,
          result: :failed,
          completed_at: ~U[2026-03-20 00:00:00Z],
          started_at: ~U[2026-03-19 23:50:00Z],
          elapsed_ms: 600_000,
          workspace_path: "/tmp/SYM-3",
          thread_id: "thread-3",
          turn_id: "turn-3",
          session_id: "session-3",
          recovery_count: 0,
          last_event: "turn_failed",
          last_message: "stale failure",
          error: "stale failure",
          error_category: "timeout"
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
        "SYM-1" => %{
          issue: issue_fixture("SYM-1", labels: ["bug"], priority: 3, assignees: ["devon"]),
          task: %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :test, 0}},
          workspace_path: "/tmp/SYM-1",
          state: :running,
          attempt: 1,
          concurrency_class: :code,
          conflict_keys: MapSet.new(["service:api"]),
          started_at: ~U[2026-03-30 00:00:10Z],
          started_at_ms: System.system_time(:millisecond) - 12_000,
          started_at_mono_ms: now_mono_ms - 12_000
        }
      },
      retry_queue: %{
        "SYM-2" => %{
          issue: issue_fixture("SYM-2", labels: ["docs"], priority: 2, assignees: ["writer"]),
          attempt: 2,
          due_at_ms: now_mono_ms + 30_000,
          queued_at: ~U[2026-03-30 00:00:20Z],
          queued_at_ms: System.system_time(:millisecond) - 7_000,
          queued_at_mono_ms: now_mono_ms - 7_000,
          backoff_ms: 30_000,
          last_result: %{
            status: :failed,
            error: "boom",
            error_category: "turn_failed",
            last_event: "turn_failed",
            last_message: "tool exploded",
            elapsed_ms: 8_000
          },
          concurrency_class: :docs,
          conflict_keys: MapSet.new(["service:docs"])
        }
      }
    }

    {:ok, server} = start_supervised({SnapshotServer, state})
    previous = Application.get_env(:symphony_ex, :dashboard_orchestrator)
    Application.put_env(:symphony_ex, :dashboard_orchestrator, server)

    on_exit(fn ->
      if previous == nil do
        Application.delete_env(:symphony_ex, :dashboard_orchestrator)
      else
        Application.put_env(:symphony_ex, :dashboard_orchestrator, previous)
      end
    end)

    %{conn: build_conn()}
  end

  test "renders the runtime dashboard with filters and inspector affordances", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/")

    assert html =~ "Symphony runtime dashboard"
    assert html =~ "Filters &amp; sorting"
    assert html =~ "Running issues"
    assert html =~ "Retry queue"
    assert html =~ "Recent completions"
    assert html =~ "Run inspector"
    assert html =~ "Inspect run"
    assert html =~ "Open full page"
    assert html =~ "Concurrency class"
    assert html =~ "Completed outcome"
    assert html =~ "Retry / completion status"
    assert html =~ "Error category"
    assert html =~ "turn_failed"
    assert html =~ "Custom…"
    assert html =~ "History window"
    assert html =~ "Completed rows"
    assert html =~ "Showing 4 matched issue(s)"
    assert html =~ "Success rate"
    assert html =~ "50.0%"
    assert html =~ "Avg runtime"
    assert html =~ "Write-back alerts"
    assert html =~ "GitHub rate limit"
    assert html =~ "4321/5000"
    assert html =~ "Orchestrator settings"
    assert html =~ "Runtime controls"
    assert html =~ "Save settings &amp; reload"
    assert html =~ "Restart orchestrator"
    assert html =~ "Restart dashboard endpoint"
    assert html =~ "Recent tracker write-back"
    assert html =~ "SYM-1"
    assert html =~ "SYM-2"
    assert html =~ "SYM-0"
    assert html =~ "/tmp/SYM-1"
    assert html =~ "service:api"
    assert html =~ "retry in"
    assert html =~ "Run details"
    assert html =~ "session-0"
    assert html =~ "tool exploded"
    assert html =~ "NDJSON breadcrumb tail"
    assert html =~ "turn.completed"
  end

  test "supports richer queue/search/class/result filtering via query params", %{conn: conn} do
    {:ok, _view, html} =
      live(
        conn,
        "/?queue=completed&q=alice&class=all&result=success&completed_window=3d&completed_limit=25"
      )

    refute html =~ ">Running issues<"
    refute html =~ ">Retry queue<"
    assert html =~ ">Recent completions<"
    assert html =~ "SYM-0"
    refute html =~ "SYM-3"
    assert html =~ "history: 3 days"
    assert html =~ "rows: 25"
    assert html =~ "Clear filters"
  end

  test "filters completed history by window and honors row limit params", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?queue=completed&completed_window=7d&completed_limit=100")

    assert html =~ "SYM-0"
    refute html =~ "SYM-3"
    assert html =~ "history: 7 days"
    assert html =~ "rows: 100"
  end

  test "filters retry/completed sections by shared status and error category", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?status=failed&error_category=timeout")

    assert html =~ "SYM-3"
    refute html =~ "SYM-2"
    assert html =~ "status: failed"
    assert html =~ "error: timeout"
    assert html =~ "stale failure"
    refute html =~ "tool exploded"

    {:ok, _view, retry_html} =
      live(recycle(conn), "/?queue=retry_queue&status=failed&error_category=turn_failed")

    assert retry_html =~ "SYM-2"
    refute retry_html =~ "SYM-3"
    assert retry_html =~ "status: failed"
    assert retry_html =~ "error: turn_failed"

    {:ok, _view, custom_html} =
      live(
        recycle(conn),
        "/?queue=retry_queue&status=failed&error_category=__custom__&error_category_custom=turn"
      )

    assert custom_html =~ "SYM-2"
    assert custom_html =~ "Custom error category contains"
    assert custom_html =~ "error: turn"
  end

  test "opens the dedicated inspector via query params", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/?run=SYM-0")

    assert html =~ "Close inspector"
    assert html =~ "Open full page"
    assert html =~ "Breadcrumb files"
    assert html =~ "GitHub write-back"
    assert html =~ "Session snapshot"
    assert html =~ "Debug artifacts"
    assert html =~ "Event timeline"
    assert html =~ ".symphony-session.json"
    assert html =~ "stderr.log"
    assert html =~ "turn.completed"
  end

  test "supports the full-page run detail route", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/runs/SYM-0?result=success")

    assert html =~ "Run detail route"
    assert html =~ "Full-page inspection view"
    assert html =~ "Back to dashboard"
    assert html =~ "Open split view"
    assert html =~ "Breadcrumb files"
    assert html =~ "GitHub write-back"
    assert html =~ "Orchestrator settings"
    assert html =~ "turn.completed"
  end

  test "applies PubSub snapshot updates", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    Dashboard.broadcast_snapshot(%{
      summary: %{
        running_count: 0,
        retry_queue_count: 0,
        completed_count: 1,
        available_slots: 3,
        max_concurrent: 3,
        write_back_alert_count: 1
      },
      running: [],
      retry_queue: [],
      completed: [
        %{
          issue: %{identifier: "SYM-99", title: "Finished issue", labels: [], priority: 4},
          attempt: 1,
          result: :success,
          completed_at: "2026-03-30T01:00:00Z",
          started_at: "2026-03-30T00:59:30Z",
          elapsed_ms: 30_000,
          workspace_path: "/tmp/SYM-99",
          thread_id: "thread-99",
          turn_id: "turn-99",
          session_id: "session-99",
          recovery_count: 0,
          last_event: "turn_completed",
          last_message: "wrapped up",
          error: nil,
          error_category: nil,
          log_excerpt: %{
            path: "/tmp/SYM-99/.symphony-run-events.ndjson",
            exists: true,
            event_count: 1,
            recent_events: [
              %{
                event: "run_finished",
                timestamp: "2026-03-30T01:00:00Z",
                message: "wrapped up",
                raw_method: nil,
                status: "success"
              }
            ]
          }
        }
      ],
      completed_issue_identifiers: ["SYM-99"],
      settings: %{
        poll_interval_ms: 2_000,
        candidate_poll_interval_ms: 10_000,
        candidate_poll_backoff_until: "2026-03-30T01:05:00Z",
        max_concurrent: 3,
        max_retries: 2,
        retry_backoff_ms: 5_000,
        max_retry_backoff_ms: 60_000,
        concurrency_limits: %{"code" => 1},
        blocked_labels: ["blocked"],
        serialization_label_prefixes: ["service:"],
        explicit_issue_identifier: nil,
        workflow_path: "/tmp/WORKFLOW.md"
      },
      write_back_stages: %{
        recent: [
          %{
            issue_identifier: "SYM-99",
            tracker_kind: "github",
            stage: "optional",
            outcome: "partial",
            failed_stage: "label_sync_failed",
            status: nil,
            reason: "labels_down",
            captured_at: "2026-03-30T01:00:00Z"
          }
        ],
        alert_count: 1
      }
    })

    html = render(view)
    assert html =~ "No issues are running right now."
    assert html =~ "Retry queue is empty."
    assert html =~ "SYM-99"
    assert html =~ "Finished issue"
    assert html =~ "session-99"
    assert html =~ "runtime 30.0 s"
    assert html =~ "NDJSON breadcrumb tail"
    assert html =~ "wrapped up"
    assert html =~ "Recent tracker write-back"
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
