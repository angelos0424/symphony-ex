defmodule SymphonyExWeb.ApiControllerTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.RunEventLogger
  alias SymphonyEx.SessionStore
  alias SymphonyExWeb.Router

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

  setup do
    now_mono_ms = System.monotonic_time(:millisecond)
    completed_workspace = temp_workspace("api-controller-completed")

    write_events!(completed_workspace, [
      %{"event" => "run_started", "timestamp" => "2026-03-29T23:59:30Z", "message" => "started"},
      %{
        "event" => "run_finished",
        "timestamp" => "2026-03-30T00:00:00Z",
        "message" => "done",
        "status" => "success"
      }
    ])

    SessionStore.save(completed_workspace, %{
      thread_id: "thread-0",
      turn_id: "turn-0",
      session_id: "session-0",
      issue_identifier: "SYM-0",
      turns_executed: 2,
      recovery_count: 0,
      last_event: "run_finished",
      phase: :completed,
      capability_profile: %{supports_thread_reuse: true}
    })

    debug_dir = Path.join([completed_workspace, ".symphony", "debug"])
    File.mkdir_p!(debug_dir)
    File.write!(Path.join(debug_dir, "stdout.log"), "done\n")

    state = %{
      explicit_issue_identifier: nil,
      completed_issue_identifiers: MapSet.new(["SYM-0"]),
      completed: [
        %{
          issue: issue_fixture("SYM-0", labels: ["feature"]),
          attempt: 1,
          result: :success,
          completed_at: ~U[2026-03-30 00:00:00Z],
          started_at: ~U[2026-03-29 23:59:30Z],
          elapsed_ms: 30_000,
          workspace_path: completed_workspace,
          thread_id: "thread-0",
          turn_id: "turn-0",
          session_id: "session-0",
          recovery_count: 0,
          last_event: "turn_completed",
          last_message: "done",
          error: nil,
          error_category: nil
        }
      ],
      workflow_path: "/tmp/WORKFLOW.md",
      poll_interval_ms: 5_000,
      max_concurrent: 2,
      max_retries: 2,
      retry_backoff_ms: 5_000,
      max_retry_backoff_ms: 30_000,
      blocked_labels: MapSet.new(["blocked"]),
      concurrency_limits: %{code: 1, default: 1},
      serialization_label_prefixes: ["service:"],
      running: %{
        "SYM-1" => %{
          issue: issue_fixture("SYM-1", labels: ["bug"]),
          task: %Task{ref: make_ref(), pid: self(), owner: self(), mfa: {__MODULE__, :test, 0}},
          workspace_path: "/tmp/SYM-1",
          state: :running,
          attempt: 0,
          concurrency_class: :code,
          conflict_keys: MapSet.new(["service:api"]),
          started_at: ~U[2026-03-30 00:00:10Z],
          started_at_ms: System.system_time(:millisecond) - 8_000,
          started_at_mono_ms: now_mono_ms - 8_000
        }
      },
      retry_queue: %{
        "SYM-2" => %{
          issue: issue_fixture("SYM-2", labels: ["docs"]),
          attempt: 1,
          due_at_ms: now_mono_ms + 15_000,
          queued_at: ~U[2026-03-30 00:00:20Z],
          queued_at_ms: System.system_time(:millisecond) - 3_000,
          queued_at_mono_ms: now_mono_ms - 3_000,
          backoff_ms: 15_000,
          last_result: %{status: :failed, error: "boom", error_category: "turn_failed"},
          concurrency_class: :default,
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

    %{server: server}
  end

  test "GET /api/v1/status returns snapshot summary and settings" do
    conn = conn(:get, "/api/v1/status") |> put_req_header("accept", "application/json")
    conn = Router.call(conn, Router.init([]))

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert body["summary"]["running_count"] == 1
    assert body["summary"]["retry_queue_count"] == 1
    assert body["summary"]["completed_count"] == 1
    assert body["settings"]["max_concurrent"] == 2
    assert body["running_count"] == 1
  end

  test "GET /api/v1/issues returns running, retry, and completed lists" do
    conn = conn(:get, "/api/v1/issues") |> put_req_header("accept", "application/json")
    conn = Router.call(conn, Router.init([]))

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert Enum.map(body["running"], & &1["issue"]["identifier"]) == ["SYM-1"]
    assert Enum.map(body["retry_queue"], & &1["issue"]["identifier"]) == ["SYM-2"]
    assert Enum.map(body["completed"], & &1["issue"]["identifier"]) == ["SYM-0"]
    assert body["running"] |> hd() |> Map.has_key?("elapsed_ms")
    assert body["retry_queue"] |> hd() |> get_in(["last_result", "status"]) == "failed"
    assert body["completed"] |> hd() |> get_in(["thread_id"]) == "thread-0"
    assert body["completed"] |> hd() |> get_in(["log_excerpt", "event_count"]) == 2
    assert body["completed_issue_identifiers"] == ["SYM-0"]
  end

  test "GET /api/v1/runs/:identifier returns detailed running, retry, or completed entries" do
    running_conn =
      conn(:get, "/api/v1/runs/SYM-1") |> put_req_header("accept", "application/json")

    running_conn = Router.call(running_conn, Router.init([]))

    assert running_conn.status == 200
    running_body = Jason.decode!(running_conn.resp_body)
    assert running_body["queue"] == "running"
    assert running_body["issue"]["identifier"] == "SYM-1"
    assert is_integer(running_body["elapsed_ms"])
    assert running_body["paths"]["events"] =~ ".symphony-run-events.ndjson"

    retry_conn = conn(:get, "/api/v1/runs/SYM-2") |> put_req_header("accept", "application/json")
    retry_conn = Router.call(retry_conn, Router.init([]))

    assert retry_conn.status == 200
    retry_body = Jason.decode!(retry_conn.resp_body)
    assert retry_body["queue"] == "retry_queue"
    assert retry_body["issue"]["identifier"] == "SYM-2"
    assert retry_body["last_result"]["error"] == "boom"

    completed_conn =
      conn(:get, "/api/v1/runs/SYM-0") |> put_req_header("accept", "application/json")

    completed_conn = Router.call(completed_conn, Router.init([]))

    assert completed_conn.status == 200
    completed_body = Jason.decode!(completed_conn.resp_body)
    assert completed_body["queue"] == "completed"
    assert completed_body["issue"]["identifier"] == "SYM-0"
    assert completed_body["session_id"] == "session-0"
    assert completed_body["session_excerpt"]["exists"] == true
    assert completed_body["session_excerpt"]["data"]["phase"] == "completed"
    assert completed_body["debug_excerpt"]["files"] == ["stdout.log"]
    assert completed_body["log_timeline"]["event_count"] == 2

    assert completed_body["log_timeline"]["recent_events"] |> Enum.map(& &1["event"]) == [
             "run_started",
             "run_finished"
           ]
  end

  test "GET /api/v1/runs/:identifier returns 404 for unknown identifiers" do
    conn = conn(:get, "/api/v1/runs/SYM-404") |> put_req_header("accept", "application/json")
    conn = Router.call(conn, Router.init([]))

    assert conn.status == 404
    body = Jason.decode!(conn.resp_body)
    assert body == %{"error" => "run_not_found", "identifier" => "SYM-404"}
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
