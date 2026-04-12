defmodule SymphonyEx.RunEventLoggerTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Domain.{Events, Issue}
  alias SymphonyEx.RunEventLogger

  test "appends run lifecycle and app-server events as ndjson" do
    workspace_path = temp_workspace("symphony-run-event")

    issue = %Issue{
      id: "issue-123",
      identifier: "SYM-123",
      title: "Add NDJSON breadcrumbs",
      description: "",
      state: "Todo"
    }

    event = %Events{
      event: :turn_completed,
      timestamp: "2026-03-29T03:00:00Z",
      raw_method: "turn.completed",
      message: "done",
      params: %{"step" => 1},
      usage: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    }

    assert :ok = RunEventLogger.log_run_started(workspace_path, issue, %{phase: "starting"})
    assert :ok = RunEventLogger.log_app_event(workspace_path, issue, "thread-1", event)

    assert :ok =
             RunEventLogger.log_run_finished(workspace_path, issue, %{
               thread_id: "thread-1",
               status: "success"
             })

    entries =
      workspace_path
      |> RunEventLogger.events_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    events = Enum.map(entries, & &1["event"])

    assert events == ["run_started", "turn_completed", "run_finished"] or
             events == ["approval_denied", "run_started", "turn_completed", "run_finished"]

    run_started = Enum.find(entries, &(&1["event"] == "run_started"))
    turn_completed = Enum.find(entries, &(&1["event"] == "turn_completed"))
    run_finished = Enum.find(entries, &(&1["event"] == "run_finished"))

    assert run_started["issue_identifier"] == "SYM-123"
    assert turn_completed["thread_id"] == "thread-1"
    assert turn_completed["usage"]["total_tokens"] == 15
    assert run_finished["status"] == "success"
  end

  test "maps approval requests to approval_denied breadcrumbs" do
    workspace_path = temp_workspace("symphony-run-event")

    issue = %Issue{
      id: "issue-456",
      identifier: "SYM-456",
      title: "Auto deny approvals",
      description: "",
      state: "Todo"
    }

    approval_event = %Events{
      event: :approval_requested,
      timestamp: "2026-03-29T03:10:00Z",
      raw_method: "approval_requested",
      message: "Need approval",
      params: %{"tool" => "bash"},
      usage: nil
    }

    assert :ok = RunEventLogger.log_app_event(workspace_path, issue, "thread-2", approval_event)

    [entry] =
      workspace_path
      |> RunEventLogger.events_path()
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert entry["event"] == "approval_denied"
    assert entry["message"] == "Need approval"
    assert entry["params"]["tool"] == "bash"
  end

  defp temp_workspace(prefix) do
    path =
      Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive, :monotonic])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
