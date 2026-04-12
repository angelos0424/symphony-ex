defmodule SymphonyEx.Test.LinearClientStub do
  @moduledoc false

  def request(request) do
    send(self(), {:linear_request, request})
    query = request.options[:json]["query"]

    body =
      if is_binary(query) and String.contains?(query, "IssueWorkflowStates") do
        %{
          "data" => %{
            "issue" => %{
              "team" => %{
                "states" => %{
                  "nodes" => [
                    %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"},
                    %{"id" => "state-2", "name" => "In Progress", "type" => "started"},
                    %{"id" => "state-3", "name" => "Done", "type" => "completed"}
                  ]
                }
              }
            }
          }
        }
      else
        %{
          "data" => %{
            "issues" => %{
              "nodes" => [
                %{
                  "id" => "issue-1",
                  "identifier" => "SYM-1",
                  "title" => "Phase 2 foundation",
                  "description" => "Ship adapter layer",
                  "url" => "https://linear.app/example/issue/SYM-1",
                  "priority" => 2,
                  "labels" => %{"nodes" => [%{"name" => "backend"}]},
                  "parent" => %{"id" => "parent-1"},
                  "children" => %{"nodes" => [%{"id" => "child-1"}]},
                  "state" => %{"id" => "state-1", "name" => "Todo", "type" => "unstarted"}
                }
              ]
            }
          }
        }
      end

    {:ok, %Req.Response{status: 200, body: body}}
  end
end

defmodule SymphonyEx.Linear.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Linear.Client
  alias SymphonyEx.Test.LinearClientStub

  test "builds candidate issue GraphQL request and extracts nodes" do
    opts = [
      api_key: "linear-key",
      team_key: "SYM",
      request_fun: &LinearClientStub.request/1
    ]

    assert {:ok, [issue]} = Client.fetch_candidate_issues(opts)
    assert issue["identifier"] == "SYM-1"

    assert_received {:linear_request, request}
    assert to_string(request.url) == "https://api.linear.app/graphql"
    assert request.headers["authorization"] == ["linear-key"]
    assert request.options[:json]["variables"]["teamKey"] == "SYM"
  end

  test "fetches workflow states for a specific issue" do
    opts = [api_key: "linear-key", request_fun: &LinearClientStub.request/1]

    assert {:ok, states} = Client.fetch_issue_workflow_states("issue-1", opts)
    assert Enum.map(states, & &1["name"]) == ["Todo", "In Progress", "Done"]

    assert_received {:linear_request, request}
    assert request.options[:json]["variables"]["issueId"] == "issue-1"
    assert String.contains?(request.options[:json]["query"], "IssueWorkflowStates")
  end
end
