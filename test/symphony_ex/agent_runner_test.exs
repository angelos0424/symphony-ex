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

  defmodule SilentAppServer do
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> %{opts: opts, cancelled: false} end)
    def subscribe(_server, _pid \\ self()), do: :ok

    def initialize(_server) do
      {:ok, %{"supportsThreadReuse" => true, "supportsEvents" => true}}
    end

    def capabilities(_server), do: %{supports_thread_reuse: true, supports_events: true}
    def start_thread(_server, _params), do: {:ok, %{"threadId" => "thread-silent"}}
    def start_turn(_server, _params), do: {:ok, %{"turnId" => "turn-silent"}}
    def get_events(_server), do: []
    def alive?(_server), do: true
    def cancel_turn(server), do: Agent.update(server, &Map.put(&1, :cancelled, true))
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)
  end

  defmodule ExitingAppServer do
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> %{opts: opts, alive: true} end)
    def subscribe(_server, _pid \\ self()), do: :ok

    def initialize(_server) do
      {:ok, %{"supportsThreadReuse" => true, "supportsEvents" => true}}
    end

    def capabilities(_server), do: %{supports_thread_reuse: true, supports_events: true}
    def start_thread(_server, _params), do: {:ok, %{"threadId" => "thread-exit"}}

    def start_turn(server, _params) do
      Agent.update(server, &Map.put(&1, :alive, false))
      {:ok, %{"turnId" => "turn-exit"}}
    end

    def get_events(_server), do: []
    def alive?(server), do: Agent.get(server, & &1.alive)
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)
  end

  defmodule CapturingAppServer do
    use Agent

    def start_link(opts) do
      send_test_message({:app_server_started, opts})

      Agent.start_link(fn ->
        %{events: [], capabilities: %{supports_thread_reuse: true, supports_events: true}}
      end)
    end

    def subscribe(_server, _pid \\ self()), do: :ok

    def initialize(_server) do
      {:ok, %{"supportsThreadReuse" => true, "supportsEvents" => true}}
    end

    def capabilities(server), do: Agent.get(server, & &1.capabilities)

    def start_thread(_server, params) do
      send_test_message({:app_server_thread_start, params})
      {:ok, %{"thread" => %{"id" => "thread-capture"}}}
    end

    def start_turn(server, params) do
      send_test_message({:app_server_turn_start, params})

      event = %Events{
        event: :turn_completed,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "turn.completed",
        message: "done",
        params: %{"turnId" => "turn-capture"},
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      }

      Agent.update(server, fn state -> %{state | events: [event]} end)
      send(self(), {:app_server_event, event})
      {:ok, %{"turnId" => "turn-capture"}}
    end

    def get_events(server), do: Agent.get(server, & &1.events)
    def alive?(_server), do: true
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)

    defp send_test_message(message) do
      if pid = Application.get_env(:symphony_ex, :agent_runner_test_pid) do
        send(pid, message)
      end
    end
  end

  defmodule SessionLogAppServer do
    use Agent

    def start_link(opts) do
      Agent.start_link(fn ->
        %{
          opts: opts,
          events: [],
          capabilities: %{supports_thread_reuse: true, supports_events: true}
        }
      end)
    end

    def subscribe(_server, _pid \\ self()), do: :ok

    def initialize(_server) do
      {:ok, %{"supportsThreadReuse" => true, "supportsEvents" => true}}
    end

    def capabilities(server), do: Agent.get(server, & &1.capabilities)
    def start_thread(_server, _params), do: {:ok, %{"threadId" => "thread-session-log"}}

    def start_turn(server, params) do
      session_log_path = Application.fetch_env!(:symphony_ex, :agent_runner_test_session_log_path)

      thread_started = %Events{
        event: :notification,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "thread/started",
        params: %{"thread" => %{"path" => session_log_path}}
      }

      turn_completed = %Events{
        event: :turn_completed,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "turn.completed",
        message: "done",
        params: %{"turnId" => "turn-session-log", "cwd" => params["cwd"]},
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      }

      Agent.update(server, fn state -> %{state | events: [turn_completed, thread_started]} end)
      send(self(), {:app_server_event, turn_completed})
      {:ok, %{"turnId" => "turn-session-log"}}
    end

    def get_events(server), do: Agent.get(server, & &1.events)
    def alive?(_server), do: true
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)
  end

  defmodule BlockedAppServer do
    use Agent

    alias SymphonyEx.Domain.Events

    def start_link(_opts) do
      Agent.start_link(fn -> %{events: [], subscriber: nil} end)
    end

    def subscribe(server, pid \\ self()) do
      Agent.update(server, &Map.put(&1, :subscriber, pid))
      :ok
    end

    def initialize(_server), do: {:ok, %{}}
    def capabilities(_server), do: %{}
    def start_thread(_server, _params), do: {:ok, %{"threadId" => "thread-blocked"}}
    def alive?(_server), do: true
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)

    def start_turn(server, _params) do
      blocked_message =
        "STATUS: BLOCKED\nThe required browser runtime dependency libatk-1.0.so.0 is missing. This requires a gstack-aware environment."

      turn_completed = %Events{
        event: :turn_completed,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "turn.completed",
        message: blocked_message,
        params: %{"turnId" => "turn-blocked"}
      }

      Agent.update(server, fn state -> %{state | events: [turn_completed]} end)

      if subscriber = Agent.get(server, & &1.subscriber) do
        send(subscriber, {:app_server_event, turn_completed})
      end

      {:ok, %{"turnId" => "turn-blocked"}}
    end

    def get_events(server), do: Agent.get(server, & &1.events)
  end

  defmodule LastMessageAppServer do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{} end)
    end

    def subscribe(_server, _pid \\ self()), do: :ok
    def initialize(_server), do: {:ok, %{"supportsThreadReuse" => true, "supportsEvents" => true}}
    def capabilities(_server), do: %{supports_thread_reuse: true, supports_events: true}
    def start_thread(_server, _params), do: {:ok, %{"threadId" => "thread-last-message"}}
    def alive?(_server), do: true
    def cancel_turn(_server), do: :ok
    def shutdown(server), do: Agent.stop(server, :normal, 1_000)

    def start_turn(server, _params) do
      earlier = %Events{
        event: :agent_message,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "agent_message",
        message: "earlier progress update",
        params: %{"turnId" => "turn-last-message"}
      }

      latest = %Events{
        event: :turn_completed,
        timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
        raw_method: "turn.completed",
        message: "latest final summary",
        params: %{"turnId" => "turn-last-message"},
        usage: %{input_tokens: 1, output_tokens: 1, total_tokens: 2}
      }

      Agent.update(server, fn _state -> %{events: [earlier, latest]} end)
      send(self(), {:app_server_event, latest})
      {:ok, %{"turnId" => "turn-last-message"}}
    end

    def get_events(server), do: Agent.get(server, & &1.events)
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

  test "marks turn timeout failures with terminal breadcrumbs" do
    workspace_path = tmp_workspace("turn-timeout")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-303")

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "mock-codex", turn_timeout_ms: 10, stall_timeout_ms: 1_000],
        app_server: SilentAppServer
      )

    assert result.status == :failed
    assert result.error_category == "turn_timeout"
    assert result.error == "Turn timeout exceeded"

    assert {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "turn_timeout"

    [run_finished | _] =
      workspace_path
      |> read_events!()
      |> Enum.filter(&(&1["event"] == "run_finished"))

    assert run_finished["error_category"] == "turn_timeout"
    assert run_finished["status"] == "failed"
  end

  test "marks stall timeout failures with terminal breadcrumbs" do
    workspace_path = tmp_workspace("stall-timeout")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-304")

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "mock-codex", turn_timeout_ms: 1_000, stall_timeout_ms: 10],
        app_server: SilentAppServer
      )

    assert result.status == :failed
    assert result.error_category == "stalled"
    assert result.error == "Stall timeout — no activity"

    assert {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "stalled"

    [run_finished | _] =
      workspace_path
      |> read_events!()
      |> Enum.filter(&(&1["event"] == "run_finished"))

    assert run_finished["error_category"] == "stalled"
    assert run_finished["status"] == "failed"
  end

  test "marks process exit failures with terminal breadcrumbs" do
    workspace_path = tmp_workspace("process-exit")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-305")

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "mock-codex", turn_timeout_ms: 1_000, stall_timeout_ms: 1_000],
        app_server: ExitingAppServer
      )

    assert result.status == :failed
    assert result.error_category == "process_exit"
    assert result.error == "Codex process exited"

    assert {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "process_exit"

    [run_finished | _] =
      workspace_path
      |> read_events!()
      |> Enum.filter(&(&1["event"] == "run_finished"))

    assert run_finished["error_category"] == "process_exit"
    assert run_finished["status"] == "failed"
  end

  test "propagates sandbox and approval settings into app-server startup and turn requests" do
    workspace_path = tmp_workspace("sandbox-config")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-306")

    Application.put_env(:symphony_ex, :agent_runner_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_ex, :agent_runner_test_pid)
    end)

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [
          command: "codex app-server",
          approval_policy: :never,
          thread_sandbox: "dangerFullAccess"
        ],
        app_server: CapturingAppServer
      )

    assert result.status == :success

    assert_receive {:app_server_started, opts}
    assert opts[:command] =~ ~s(codex app-server)
    assert opts[:command] =~ ~s(sandbox_mode="danger-full-access")
    assert opts[:command] =~ ~s(approval_policy="never")

    assert_receive {:app_server_thread_start, thread_params}
    assert thread_params["cwd"] == workspace_path
    assert thread_params["approvalPolicy"] == "never"
    assert thread_params["sandbox"] == "danger-full-access"

    assert_receive {:app_server_turn_start, turn_params}
    assert turn_params["cwd"] == workspace_path
    assert turn_params["threadId"] == "thread-capture"
    assert is_list(turn_params["input"])
    assert [%{"type" => "text", "text" => _prompt}] = turn_params["input"]
    assert turn_params["sandboxPolicy"] == %{"type" => "dangerFullAccess"}
  end

  test "adds native Codex skill input items for referenced gstack skills" do
    workspace_path = tmp_workspace("gstack-skill-input")
    workflow_path = write_workflow(workspace_path)
    skill_root = Path.join(workspace_path, "gstack-root")
    skill_path = Path.join([skill_root, "gstack-design-review", "SKILL.md"])
    issue = %Issue{issue_fixture("SYM-306A") | description: "$gstack-design-review 실행"}

    File.mkdir_p!(Path.dirname(skill_path))
    File.write!(skill_path, "# gstack design review\n")

    previous_gstack_root = System.get_env("GSTACK_ROOT")
    System.put_env("GSTACK_ROOT", skill_root)
    Application.put_env(:symphony_ex, :agent_runner_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:symphony_ex, :agent_runner_test_pid)

      if previous_gstack_root do
        System.put_env("GSTACK_ROOT", previous_gstack_root)
      else
        System.delete_env("GSTACK_ROOT")
      end
    end)

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"],
        app_server: CapturingAppServer
      )

    assert result.status == :success

    assert_receive {:app_server_turn_start, turn_params}

    assert [
             %{"type" => "text", "text" => prompt},
             %{"type" => "skill", "name" => "gstack-design-review", "path" => ^skill_path}
           ] =
             turn_params["input"]

    assert prompt =~ "$gstack-design-review"
  end

  test "reclassifies blocked completion as failed" do
    workspace_path = tmp_workspace("blocked-result")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-309")

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"],
        app_server: BlockedAppServer
      )

    assert result.status == :failed
    assert result.error_category == "blocked"
    assert result.error =~ "blocked outcome"

    {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "blocked"
  end

  test "captures the latest event message as last_message" do
    workspace_path = tmp_workspace("last-message-order")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-309A")

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"],
        app_server: LastMessageAppServer
      )

    assert result.status == :success
    assert result.last_message == "latest final summary"
  end

  test "fails success verification when issue body update was required but not performed" do
    workspace_path = tmp_workspace("required-body-update")
    workflow_path = write_workflow(workspace_path)
    issue = %Issue{issue_fixture("SYM-310") | description: "이슈 본문에 업데이트"}

    Application.put_env(:symphony_ex, :agent_runner_issue_body_fetcher, fn _issue ->
      {:ok, issue.description}
    end)

    Application.put_env(:symphony_ex, :agent_runner_issue_pr_fetcher, fn _issue ->
      {:ok, []}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_ex, :agent_runner_issue_body_fetcher)
      Application.delete_env(:symphony_ex, :agent_runner_issue_pr_fetcher)
    end)

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"],
        app_server: MockAppServer
      )

    assert result.status == :failed
    assert result.error_category == "required_output_missing"
    assert result.error =~ "body update"

    {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "required_output_missing"
  end

  test "accepts success verification when a linked PR exists even if body text is unchanged" do
    workspace_path = tmp_workspace("required-body-pr")
    workflow_path = write_workflow(workspace_path)
    issue = %Issue{issue_fixture("SYM-311") | description: "이슈 본문에 업데이트"}

    Application.put_env(:symphony_ex, :agent_runner_issue_body_fetcher, fn _issue ->
      {:ok, issue.description}
    end)

    Application.put_env(:symphony_ex, :agent_runner_issue_pr_fetcher, fn _issue ->
      {:ok, [%{"body" => "Fixes #SYM-311", "headRefName" => "codex/issue-SYM-311-branch"}]}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_ex, :agent_runner_issue_body_fetcher)
      Application.delete_env(:symphony_ex, :agent_runner_issue_pr_fetcher)
    end)

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"],
        app_server: MockAppServer
      )

    assert result.status == :success
  end

  test "rejects unrelated existing PRs when issue targets a specific PR branch" do
    workspace_path = tmp_workspace("required-body-target-pr")
    workflow_path = write_workflow(workspace_path)

    issue = %Issue{
      issue_fixture("SYM-312")
      | description: "이슈 본문에 업데이트",
        target_pr: 19,
        target_branch: "codex/issue-19-branch"
    }

    Application.put_env(:symphony_ex, :agent_runner_issue_body_fetcher, fn _issue ->
      {:ok, issue.description}
    end)

    Application.put_env(:symphony_ex, :agent_runner_issue_pr_fetcher, fn _issue ->
      {:ok,
       [
         %{
           "number" => 18,
           "body" => "Fixes #SYM-312",
           "headRefName" => "codex/issue-SYM-312-branch"
         }
       ]}
    end)

    on_exit(fn ->
      Application.delete_env(:symphony_ex, :agent_runner_issue_body_fetcher)
      Application.delete_env(:symphony_ex, :agent_runner_issue_pr_fetcher)
    end)

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"],
        app_server: MockAppServer
      )

    assert result.status == :failed
    assert result.error_category == "required_output_missing"
  end

  test "fails before startup when a referenced gstack skill is missing" do
    workspace_path = tmp_workspace("missing-skill")
    workflow_path = write_workflow(workspace_path)

    previous_gstack_root = System.get_env("GSTACK_ROOT")
    System.put_env("GSTACK_ROOT", Path.join(workspace_path, "missing-gstack-root"))

    on_exit(fn ->
      if previous_gstack_root do
        System.put_env("GSTACK_ROOT", previous_gstack_root)
      else
        System.delete_env("GSTACK_ROOT")
      end
    end)

    issue = %Issue{issue_fixture("SYM-308") | description: "$gstack-not-installed 실행"}

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "codex app-server"]
      )

    assert result.status == :failed
    assert result.error_category == "missing_skill_reference"
    assert result.error =~ "Referenced skill $gstack-not-installed is not installed"

    {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "missing_skill_reference"
  end

  test "reclassifies turn completion as failed when the codex session log records a fatal tool error" do
    workspace_path = tmp_workspace("tool-failure-session-log")
    workflow_path = write_workflow(workspace_path)
    issue = issue_fixture("SYM-307")
    session_log_path = Path.join(workspace_path, "codex-session.jsonl")

    File.mkdir_p!(workspace_path)

    File.write!(
      session_log_path,
      Enum.join(
        [
          Jason.encode!(%{
            "type" => "event_msg",
            "payload" => %{"type" => "task_started", "turn_id" => "turn-session-log"}
          }),
          Jason.encode!(%{
            "type" => "response_item",
            "payload" => %{
              "type" => "function_call_output",
              "output" =>
                "write_stdin failed: stdin is closed for this session; rerun exec_command with tty=true to keep stdin open"
            }
          }),
          Jason.encode!(%{
            "type" => "event_msg",
            "payload" => %{"type" => "task_complete", "turn_id" => "turn-session-log"}
          })
        ],
        "\n"
      ) <> "\n"
    )

    Application.put_env(:symphony_ex, :agent_runner_test_session_log_path, session_log_path)

    on_exit(fn ->
      Application.delete_env(:symphony_ex, :agent_runner_test_session_log_path)
    end)

    result =
      AgentRunner.run(issue,
        workspace_path: workspace_path,
        workflow_path: workflow_path,
        codex: [command: "mock-codex"],
        app_server: SessionLogAppServer
      )

    assert result.status == :failed
    assert result.error_category == "tool_execution_failed"
    assert result.error =~ "write_stdin failed"

    assert {:ok, session} = SessionStore.load(workspace_path)
    assert session.phase == :failed
    assert session.error_category == "tool_execution_failed"

    [run_finished | _] =
      workspace_path
      |> read_events!()
      |> Enum.filter(&(&1["event"] == "run_finished"))

    assert run_finished["status"] == "failed"
    assert run_finished["error_category"] == "tool_execution_failed"
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
