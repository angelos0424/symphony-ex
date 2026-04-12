defmodule SymphonyEx.AgentRunnerTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.AgentRunner
  alias SymphonyEx.Domain.{Events, Issue}
  alias SymphonyEx.SessionStore

  defmodule MockAppServer do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn ->
        %{opts: opts, started_threads: [], events: [], capabilities: %{}}
      end)
    end

    def subscribe(_server, _pid \\ self()), do: :ok

    def initialize(server) do
      Agent.update(server, fn state ->
        %{state | capabilities: %{supports_thread_reuse: true, supports_events: true}}
      end)

      {:ok, %{"supportsThreadReuse" => true, "supportsEvents" => true}}
    end

    def capabilities(server), do: Agent.get(server, & &1.capabilities)

    def start_thread(server, params) do
      thread_id = Map.get(params, "threadId", "thread-new")

      Agent.update(server, fn state ->
        %{state | started_threads: [params | state.started_threads]}
      end)

      {:ok, %{"threadId" => thread_id}}
    end

    def start_turn(server, _params) do
      event = %Events{
        event: :turn_completed,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "turn.completed",
        message: "done",
        params: %{"turnId" => "turn-123"},
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      }

      Agent.update(server, fn state -> %{state | events: [event]} end)
      send(self(), {:app_server_event, event})
      {:ok, %{"turnId" => "turn-123"}}
    end

    def get_events(server), do: Agent.get(server, & &1.events)
    def alive?(_server), do: true
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)
  end

  defmodule FailingAppServer do
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> %{opts: opts, capabilities: %{}} end)
    def subscribe(_server, _pid \\ self()), do: :ok

    def initialize(server) do
      Agent.update(server, &Map.put(&1, :capabilities, %{}))
      {:error, :boom}
    end

    def capabilities(server), do: Agent.get(server, & &1.capabilities)
    def start_thread(_server, _params), do: raise("start_thread should not be called")
    def start_turn(_server, _params), do: raise("start_turn should not be called")
    def get_events(_server), do: []
    def alive?(_server), do: false
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)
  end

  test "reuses recoverable thread metadata and clears session file on success" do
    workspace_path = tmp_workspace("recovery-success")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-301")

    assert {:ok, _saved} =
             SessionStore.save(workspace_path, %{
               session_id: "session-existing",
               issue_id: issue.id,
               issue_identifier: issue.identifier,
               thread_id: "thread-existing",
               turn_id: "turn-old",
               turns_executed: 1,
               capability_profile: %{supports_thread_reuse: true},
               recovery_count: 0,
               last_event: "turn_failed",
               phase: :running
             })

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "mock-codex"],
        app_server: MockAppServer
      )

    assert result.status == :success
    assert result.thread_id == "thread-existing"
    assert result.turn_id == "turn-123"
    assert result.last_event == "turn_completed"

    assert {:ok, nil} = SessionStore.load(workspace_path)

    events = read_events!(workspace_path)
    [run_started | _] = Enum.filter(events, &(&1["event"] == "run_started"))
    [run_finished | _] = Enum.filter(events, &(&1["event"] == "run_finished"))

    assert run_started["recovered"] == true
    assert run_started["recovery_count"] == 1
    assert run_started["thread_id"] == "thread-existing"
    assert run_finished["outcome_kind"] == "progressed"
    assert run_finished["thread_id"] == "thread-existing"
    assert run_finished["turn_id"] == "turn-123"
    assert is_integer(run_finished["elapsed_ms"])
    assert File.exists?(Path.join(workspace_path, ".symphony-run-events.ndjson"))
  end

  test "writes failed breadcrumbs when startup fails before a turn completes" do
    workspace_path = tmp_workspace("startup-failure")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-302")

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "mock-codex"],
        app_server: FailingAppServer
      )

    assert result.status == :failed
    assert result.error_category == "startup_failed"

    assert {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.last_event == "startup_failed"
    assert session.error =~ ":boom"
    assert session.error_category == "startup_failed"
  end

  defp issue_fixture(identifier) do
    %Issue{
      id: "issue-#{identifier}",
      identifier: identifier,
      title: "Test issue #{identifier}",
      description: "body",
      state: "Todo"
    }
  end

  defp write_workflow(workspace_path) do
    workflow_path = Path.join(workspace_path, "WORKFLOW.md")
    File.mkdir_p!(workspace_path)
    File.write!(workflow_path, "Task: <%= issue.title %>\n")
    workflow_path
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-agent-runner-#{name}-#{System.unique_integer([:positive])}"
    )
  end

  defp read_events!(workspace_path) do
    workspace_path
    |> Path.join(".symphony-run-events.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
