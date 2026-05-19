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
            issue_body:
              Keyword.get(
                opts,
                :issue_body,
                "Service: api\nPaths: lib/symphony_ex/orchestrator.ex"
              ),
            blocked_by: Keyword.get(opts, :blocked_by, []),
            inbound_issue_comments: Keyword.get(opts, :inbound_issue_comments, []),
            run_calls: [],
            run_descriptions: [],
            issue_state_updates: [],
            issue_bodies: [],
            issue_comments: [],
            comment_reactions: []
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

    def record_run(issue) do
      Agent.update(__MODULE__, fn state ->
        %{
          state
          | run_calls: [issue.identifier | state.run_calls],
            run_descriptions: [issue.description | state.run_descriptions]
        }
      end)
    end

    def snapshot do
      Agent.get(__MODULE__, fn state ->
        %{
          project_status: state.project_status,
          run_calls: Enum.reverse(state.run_calls),
          run_descriptions: Enum.reverse(state.run_descriptions),
          issue_state_updates: Enum.reverse(state.issue_state_updates),
          issue_bodies: Enum.reverse(state.issue_bodies),
          issue_comments: Enum.reverse(state.issue_comments),
          comment_reactions: Enum.reverse(state.comment_reactions)
        }
      end)
    end

    def set_issue_body(body) do
      Agent.update(__MODULE__, &Map.put(&1, :issue_body, body))
    end

    def set_blocked_by(blocked_by) do
      Agent.update(__MODULE__, &Map.put(&1, :blocked_by, blocked_by))
    end

    def set_project_status(status) do
      Agent.update(__MODULE__, &Map.put(&1, :project_status, status))
    end

    def set_inbound_issue_comments(comments) do
      Agent.update(__MODULE__, &Map.put(&1, :inbound_issue_comments, comments))
    end

    defp handle_request(request, state) do
      cond do
        request.method == :get and
            String.ends_with?(
              to_string(request.url),
              "/repos/example/repo/issues/12/dependencies/blocked_by"
            ) ->
          {{:ok, %Req.Response{status: 200, body: state.blocked_by}}, state}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          issue = %{
            "id" => "I_12",
            "number" => 12,
            "title" => "Implement tracker abstraction",
            "body" => state.issue_body,
            "html_url" => "https://github.com/example/repo/issues/12",
            "state" => "open",
            "labels" => []
          }

          {{:ok, %Req.Response{status: 200, body: issue}}, state}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {{:ok, project_items_response(state.project_status, state.issue_body)}, state}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "mutation UpdateProject") ->
          option_id = request.options[:json]["variables"]["optionId"]
          project_status = project_status_for(option_id)

          response = %{
            "data" => %{
              "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_12"}}
            }
          }

          {{:ok, %Req.Response{status: 200, body: response}},
           %{state | project_status: project_status}}

        request.method == :patch and
          String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") and
            is_binary(request.options[:json][:body]) ->
          body = request.options[:json][:body]
          response = %{"body" => body}

          {{:ok, %Req.Response{status: 200, body: response}},
           %{state | issue_bodies: [body | state.issue_bodies]}}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/comments") ->
          {{:ok, %Req.Response{status: 200, body: state.inbound_issue_comments}}, state}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/3/comments") ->
          {{:ok, %Req.Response{status: 200, body: []}}, state}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/pulls/3/comments") ->
          {{:ok, %Req.Response{status: 200, body: []}}, state}

        request.method == :post and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/comments") ->
          body = request.options[:json][:body]
          response = %{"body" => body}

          {{:ok, %Req.Response{status: 201, body: response}},
           %{state | issue_comments: [body | state.issue_comments]}}

        request.method == :post and
          String.contains?(to_string(request.url), "/repos/example/repo/issues/comments/") and
            String.ends_with?(to_string(request.url), "/reactions") ->
          reaction = %{
            url: to_string(request.url),
            content: request.options[:json][:content]
          }

          {{:ok, %Req.Response{status: 201, body: reaction}},
           state
           |> Map.update!(:comment_reactions, &[reaction | &1])
           |> put_inbound_comment_reaction(reaction.url, reaction.content)}

        request.method == :post and
          String.contains?(to_string(request.url), "/repos/example/repo/pulls/comments/") and
            String.ends_with?(to_string(request.url), "/reactions") ->
          reaction = %{
            url: to_string(request.url),
            content: request.options[:json][:content]
          }

          {{:ok, %Req.Response{status: 201, body: reaction}},
           state
           |> Map.update!(:comment_reactions, &[reaction | &1])
           |> put_inbound_comment_reaction(reaction.url, reaction.content)}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/pulls") ->
          {{:ok, %Req.Response{status: 200, body: []}}, state}

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

    defp project_items_response(status_name, issue_body) do
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
                        "body" => issue_body,
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
                                %{"id" => "opt_review", "name" => "In Review"},
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
    defp project_status_for("opt_review"), do: "In Review"
    defp project_status_for("opt_done"), do: "Done"
    defp project_status_for(_other), do: "Todo"

    defp put_inbound_comment_reaction(state, url, content) do
      case Regex.run(~r{/comments/(\d+)/reactions$}, to_string(url)) do
        [_full, raw_id] ->
          {comment_id, ""} = Integer.parse(raw_id)

          Map.update!(state, :inbound_issue_comments, fn comments ->
            Enum.map(comments, fn
              %{"id" => ^comment_id} = comment -> add_reaction_count(comment, content)
              comment -> comment
            end)
          end)

        _other ->
          state
      end
    end

    defp add_reaction_count(comment, content) do
      reactions = Map.get(comment, "reactions") || %{"total_count" => 0}
      current = Map.get(reactions, content, 0)
      total = Map.get(reactions, "total_count", 0)

      comment
      |> Map.put(
        "reactions",
        reactions |> Map.put(content, current + 1) |> Map.put("total_count", total + 1)
      )
    end

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
      Control.record_run(issue)
      %{status: :success, events: [], error: nil}
    end
  end

  defmodule MockFailingAgentRunner do
    def run(issue, _opts) do
      Control.record_run(issue)
      %{status: :failed, events: [], error: "blocked", error_category: "test_blocked"}
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: SymphonyEx.IntegrationAgentWorkers})

    start_supervised!({Control, test_pid: self()})

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
    assert control.project_status == "In Review"
    assert control.run_calls == ["12"]
    assert control.issue_state_updates == []

    assert Enum.any?(control.issue_comments, &String.contains?(&1, "status: claimed"))
    assert Enum.any?(control.issue_comments, &String.contains?(&1, "status: running"))
    assert Enum.any?(control.issue_comments, &String.contains?(&1, "result: success"))
    assert Enum.any?(control.issue_bodies, &String.contains?(&1, "## Symphony Status"))
    assert Enum.any?(control.issue_bodies, &String.contains?(&1, "- Final status: in_review"))
    assert Enum.any?(control.issue_bodies, &String.contains?(&1, "- Pull request: none"))
  end

  test "processes @Task review feedback while issue remains In Review after a completed run" do
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
           review_task_states: ["In Review"],
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

      Control.snapshot().run_calls == ["12"] and length(snapshot.completed) == 1 and
        map_size(snapshot.running) == 0
    end)

    Control.set_issue_body(
      "Service: docs\nPaths: .review/2026-04-24.md\nTarget-PR: 3\nTarget-Branch: codex/review-doc\n\n<!-- symphony:review-tasks -->\nprocessed_task: issue-comment:1001\n<!-- /symphony:review-tasks -->\n"
    )

    Control.set_project_status("In Review")

    Control.set_inbound_issue_comments([
      %{
        "id" => 1001,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task\n리뷰 문서의 실행 방법을 보완해줘.",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1001"
      },
      %{
        "id" => 1002,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task review comment",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1002"
      },
      %{
        "id" => 1003,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task review",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1003"
      }
    ])

    send(orchestrator, :tick)

    wait_until(fn -> Control.snapshot().run_calls == ["12", "12"] end, 100)

    control = Control.snapshot()
    assert control.project_status == "In Review"
    assert control.run_calls == ["12", "12"]
    assert List.last(control.run_descriptions) =~ "## Review Follow-up Task"
    assert List.last(control.run_descriptions) =~ "리뷰 문서의 실행 방법을 보완해줘."

    assert List.last(control.run_descriptions) =~
             "`@Task review comment`: inspect the review comments"

    assert List.last(control.run_descriptions) =~
             "`@Task review`: review the current target PR diff"

    assert List.last(control.run_descriptions) =~ "$gstack-design-review"
    assert List.last(control.run_descriptions) =~ "$gstack-eng-review"

    assert List.last(control.run_descriptions) =~
             "Completion requires a visible PR review result"

    assert List.last(control.run_descriptions) =~
             "Do not edit files, create commits, or push changes for plain `@Task review`"

    assert List.last(control.run_descriptions) =~
             "verdict (`approved`, `commented`, `changes-requested`, or `changes-applied`)"

    assert List.last(control.run_descriptions) =~ "work result summary (`작업 결과 요약`)"

    assert List.last(control.run_descriptions) =~
             "Only apply code changes when the task explicitly asks to apply or fix feedback"

    assert Enum.any?(
             control.issue_bodies,
             &String.contains?(&1, "processed_task: issue-comment:1001 status: success")
           )

    assert Enum.map(control.comment_reactions, & &1.content) == [
             "eyes",
             "eyes",
             "eyes",
             "rocket",
             "rocket",
             "rocket",
             "+1",
             "+1",
             "+1"
           ]

    assert Enum.any?(
             control.comment_reactions,
             &String.ends_with?(&1.url, "/issues/comments/1001/reactions")
           )
  end

  test "skips @Task comments with successful processed status even without reactions" do
    Control.set_issue_body(
      "Service: docs\nPaths: .review/2026-04-24.md\nTarget-PR: 3\nTarget-Branch: codex/review-doc\n\n<!-- symphony:review-tasks -->\nprocessed_task: issue-comment:1001 status: success\n<!-- /symphony:review-tasks -->\n"
    )

    Control.set_project_status("In Review")

    Control.set_inbound_issue_comments([
      %{
        "id" => 1001,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task\n리뷰 문서의 실행 방법을 보완해줘.",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1001"
      }
    ])

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
           review_task_states: ["In Review"],
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

    Process.sleep(75)

    snapshot = Orchestrator.snapshot(orchestrator)
    control = Control.snapshot()

    assert snapshot.completed == []
    assert control.run_calls == []
    assert control.comment_reactions == []
  end

  test "skips @Task comments that already have Symphony completion reactions" do
    Control.set_issue_body(
      "Service: docs\nPaths: .review/2026-04-24.md\nTarget-PR: 3\nTarget-Branch: codex/review-doc\n"
    )

    Control.set_project_status("In Review")

    Control.set_inbound_issue_comments([
      %{
        "id" => 1001,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task\n리뷰 문서의 실행 방법을 보완해줘.",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1001",
        "reactions" => %{"+1" => 1, "total_count" => 1}
      }
    ])

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
           review_task_states: ["In Review"],
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

    Process.sleep(75)

    snapshot = Orchestrator.snapshot(orchestrator)
    control = Control.snapshot()

    assert snapshot.completed == []
    assert control.run_calls == []
    assert control.comment_reactions == []
  end

  test "skips @Task comments already claimed or blocked by lifecycle reactions" do
    Control.set_issue_body(
      "Service: docs\nPaths: .review/2026-04-24.md\nTarget-PR: 3\nTarget-Branch: codex/review-doc\n"
    )

    Control.set_project_status("In Review")

    Control.set_inbound_issue_comments([
      %{
        "id" => 1001,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task\n리뷰 문서의 실행 방법을 보완해줘.",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1001",
        "reactions" => %{"eyes" => 1, "total_count" => 1}
      },
      %{
        "id" => 1002,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task\n막힌 작업을 다시 봐줘.",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1002",
        "reactions" => %{"-1" => 1, "total_count" => 1}
      }
    ])

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
           review_task_states: ["In Review"],
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

    Process.sleep(75)

    snapshot = Orchestrator.snapshot(orchestrator)
    control = Control.snapshot()

    assert snapshot.completed == []
    assert control.run_calls == []
    assert control.comment_reactions == []
  end

  test "marks failed @Task review follow-up with blocked reaction" do
    Control.set_issue_body("Service: docs\nPaths: .review/2026-04-24.md\n")
    Control.set_project_status("In Review")

    Control.set_inbound_issue_comments([
      %{
        "id" => 1001,
        "user" => %{"login" => "reviewer"},
        "body" => "@Task\n다시 확인해줘.",
        "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1001"
      }
    ])

    orchestrator =
      start_supervised!(
        {Orchestrator,
         tracker: SymphonyEx.GitHub.Adapter,
         workspace: MockWorkspace,
         agent_runner: MockFailingAgentRunner,
         tracker_opts: [
           api_key: "gh-token",
           owner: "example",
           repo: "repo",
           project_number: 7,
           active_states: ["Todo", "In Progress"],
           review_task_states: ["In Review"],
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
         max_retries: 0,
         max_concurrent: 1,
         task_supervisor: SymphonyEx.IntegrationAgentWorkers}
      )

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      Control.snapshot().run_calls == ["12"] and length(snapshot.completed) == 1
    end)

    control = Control.snapshot()
    assert control.project_status == "In Review"
    assert Enum.map(control.comment_reactions, & &1.content) == ["eyes", "rocket", "-1"]
  end

  test "skips ambiguous issues with a visible missing metadata reason" do
    Control.set_issue_body("Service: api")

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
      control = Control.snapshot()

      control.run_calls == [] and
        Enum.any?(
          control.issue_comments,
          &String.contains?(&1, "gating_reason: missing_required_metadata")
        )
    end)

    snapshot = Orchestrator.snapshot(orchestrator)
    control = Control.snapshot()

    assert length(snapshot.completed) == 0
    assert control.project_status == "Todo"

    assert Enum.any?(
             control.issue_comments,
             &String.contains?(&1, "missing_required_fields: [:paths]")
           )
  end

  test "keeps dependency-blocked issues visible and picks them up after the dependency clears" do
    Control.set_blocked_by([
      %{
        "number" => 91,
        "state" => "open",
        "title" => "Blocking issue",
        "html_url" => "https://github.com/example/repo/issues/91"
      }
    ])

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
      control = Control.snapshot()

      control.run_calls == [] and
        Enum.any?(
          control.issue_comments,
          &String.contains?(&1, "gating_reason: dependency_blocked")
        )
    end)

    control = Control.snapshot()

    assert Enum.any?(
             control.issue_comments,
             &String.contains?(&1, "blocked_by_identifiers: [\"91\"]")
           )

    Control.set_blocked_by([])
    Process.sleep(50)
    send(orchestrator, :tick)

    wait_until(fn ->
      snapshot = Orchestrator.snapshot(orchestrator)
      control = Control.snapshot()
      length(snapshot.completed) == 1 and control.run_calls == ["12"]
    end)

    final = Control.snapshot()
    assert final.project_status == "In Review"
    assert final.run_calls == ["12"]
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
