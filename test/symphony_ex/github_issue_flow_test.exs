defmodule SymphonyEx.GitHubIssueFlowTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Orchestrator

  defmodule Control do
    use Agent

    def start_link(opts) do
      Agent.start_link(
        fn ->
          %{
            test_pid: Keyword.fetch!(opts, :test_pid),
            project_status: "Todo",
            run_calls: [],
            issue_state_updates: [],
            issue_bodies: []
          }
        end,
        name: __MODULE__
      )
    end

    def request(request) do
      Agent.get_and_update(__MODULE__, fn state ->
        send(state.test_pid, {:github_request, request})
        handle_request(request, state)
      end)
    end

    def record_run(identifier) do
      Agent.update(__MODULE__, fn state ->
        %{state | run_calls: [identifier | state.run_calls]}
      end)
    end

    def snapshot do
      Agent.get(__MODULE__, fn state ->
        %{
          project_status: state.project_status,
          run_calls: Enum.reverse(state.run_calls),
          issue_state_updates: Enum.reverse(state.issue_state_updates),
          issue_bodies: Enum.reverse(state.issue_bodies)
        }
      end)
    end

    defp handle_request(request, state) do
      cond do
        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {{:ok, project_items_response(state.project_status)}, state}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "mutation UpdateProject") ->
          option_id = request.options[:json]["variables"]["optionId"]
          project_status = project_status_for(option_id)

          response = %{
            "data" => %{
              "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_12"}}
            }
          }

          {{:ok, %Req.Response{status: 200, body: response}}, %{state | project_status: project_status}}

        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") and
            is_binary(request.options[:json][:body]) ->
          body = request.options[:json][:body]
          response = %{"body" => body}
          {{:ok, %Req.Response{status: 200, body: response}}, %{state | issue_bodies: [body | state.issue_bodies]}}

        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          issue_state = request.options[:json][:state]
          response = %{"state" => issue_state}

          {{:ok, %Req.Response{status: 200, body: response}},
           %{state | issue_state_updates: [issue_state | state.issue_state_updates]}}

        true ->
          {error_response(request), state}
      end
    end

    defp project_items_response(status_name) do
      %Req.Response{
        status: 200,
        body: %{
          "data" => %{
            "organization" => %{
              "projectV2" => %{
                "id" => "PVT_1",
                "items" => %{
                  "nodes" => [
                    %{
                      "id" => "PVTI_12",
                      "content" => %{
                        "id" => "I_12",
                        "number" => 12,
                        "title" => "Implement tracker abstraction",
                        "body" => "Original body",
                        "url" => "https://github.com/example/repo/issues/12",
                        "state" => "OPEN"
                      },
                      "fieldValues" => %{
                        "nodes" => [
                          %{
                            "name" => status_name,
                            "field" => %{
                              "id" => "status-field",
                              "name" => "Status",
                              "options" => [
                                %{"id" => "opt_todo", "name" => "Todo"},
                                %{"id" => "opt_progress", "name" => "In Progress"},
                                %{"id" => "opt_done", "name" => "Done"}
                              ]
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            },
            "user" => nil
          }
        }
      }
    end

    defp project_status_for("opt_progress"), do: "In Progress"
    defp project_status_for("opt_done"), do: "Done"
    defp project_status_for(_other), do: "Todo"

    defp error_response(request) do
      flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
    end
  end

  defmodule MockWorkspace do
    def prepare(issue, _opts), do: {:ok, %{path: "/tmp/#{issue.identifier}", reason: :fresh}}
    def remove(_path, _opts), do: :ok
    def run_lifecycle_hook(_name, _path, _opts, _issue), do: :ok
  end

  defmodule MockAgentRunner do
    def run(issue, _opts) do
      Control.record_run(issue.identifier)
      %{status: :success, events: [], error: nil}
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: SymphonyEx.IntegrationAgentWorkers})

    start_supervised!(
      {Control, test_pid: self()}
    )

    :ok
  end

  test "processes one GitHub Todo issue through run and write-back without duplicate pickup" do
    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: SymphonyEx.GitHub.Adapter,
         workspace: MockWorkspace,
         agent_runner: MockAgentRunner,
         tracker_opts: [
           api_key: "gh-token",
           owner: "example",
           repo: "repo",
           project_number: 7,
           active_states: ["Todo", "In Progress"],
           terminal_states: ["Done"],
           write_back: [in_progress_state_names: ["In Progress"]],
           request_fun: &Control.request/1
         ],
         workspace_opts: [],
         workflow_path: "/tmp/WORKFLOW.md",
         codex: [],
         poll_interval_ms: 25,
         retry_backoff_ms: 10,
         max_retry_backoff_ms: 10,
         max_retries: 1,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.IntegrationAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      length(snapshot.completed) == 1 and map_size(snapshot.running) == 0
    end)

    Process.sleep(75)

    snapshot = Orchestrator.snapshot(orchestrator)
    control = Control.snapshot()

    assert length(snapshot.completed) == 1
    assert control.project_status == "Done"
    assert control.run_calls == ["12"]
    assert "closed" in control.issue_state_updates

    assert Enum.any?(control.issue_bodies, &String.contains?(&1, "status: claimed"))
    assert Enum.any?(control.issue_bodies, &String.contains?(&1, "status: running"))
    assert Enum.any?(control.issue_bodies, &String.contains?(&1, "result: success"))
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
