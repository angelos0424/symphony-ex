defmodule SymphonyEx.Linear.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.Linear.Adapter

  test "maps Linear issue payload into tracker-agnostic issue struct" do
    payload = %{
      "id" => "issue-1",
      "identifier" => "SYM-1",
      "title" => "Implement tracker abstraction",
      "description" => "Need adapter",
      "url" => "https://linear.app/example/issue/SYM-1",
      "priority" => 3,
      "labels" => %{"nodes" => [%{"name" => "backend"}, %{"name" => "elixir"}]},
      "parent" => %{"id" => "parent-1"},
      "children" => %{"nodes" => [%{"id" => "child-1"}, %{"id" => "child-2"}]},
      "state" => %{"name" => "In Progress"}
    }

    assert %Issue{} = issue = Adapter.to_issue(payload)
    assert issue.identifier == "SYM-1"
    assert issue.labels == ["backend", "elixir"]
    assert issue.children_ids == ["child-1", "child-2"]
    assert issue.state == "In Progress"
  end

  test "upserts managed working record block" do
    description = "Existing notes"

    updated = Adapter.upsert_managed_working_record(description, "run status: claimed")

    assert updated =~ "Existing notes"
    assert updated =~ "<!-- symphony:managed -->"
    assert updated =~ "run status: claimed"

    replaced = Adapter.upsert_managed_working_record(updated, "run status: running")

    assert replaced =~ "run status: running"
    refute replaced =~ "run status: claimed"
  end

  test "resolves desired state aliases against workflow states" do
    issue = %Issue{
      id: "issue-1",
      identifier: "SYM-1",
      title: "Title",
      description: "",
      state: "Todo"
    }

    request_fun = fn request ->
      query = request.options[:json]["query"]

      body =
        cond do
          String.contains?(query, "IssueWorkflowStates") ->
            %{
              "data" => %{
                "issue" => %{
                  "team" => %{
                    "states" => %{
                      "nodes" => [
                        %{"id" => "state-a", "name" => "Backlog", "type" => "unstarted"},
                        %{"id" => "state-b", "name" => "Started", "type" => "started"},
                        %{"id" => "state-c", "name" => "Done", "type" => "completed"}
                      ]
                    }
                  }
                }
              }
            }

          String.contains?(query, "UpdateIssueState") ->
            assert request.options[:json]["variables"] == %{
                     "issueId" => "issue-1",
                     "stateId" => "state-b"
                   }

            %{"data" => %{"issueUpdate" => %{"success" => true, "issue" => %{"id" => "issue-1"}}}}
        end

      {:ok, %Req.Response{status: 200, body: body}}
    end

    opts = [api_key: "linear-key", request_fun: request_fun]

    assert {:ok, state} = Adapter.resolve_issue_state(issue, :in_progress, opts)
    assert state["id"] == "state-b"

    assert {:ok, %{"success" => true}} = Adapter.update_issue_state(issue, :in_progress, opts)
  end

  test "renders a managed run record body with metadata" do
    issue = %Issue{
      id: "issue-1",
      identifier: "SYM-1",
      title: "Title",
      description: "",
      state: "Todo"
    }

    body = Adapter.render_run_record(issue, %{status: :retry_queued, attempt: 2, backoff_ms: 10})

    assert body =~ "issue: SYM-1"
    assert body =~ "status: retry_queued"
    assert body =~ "attempt: 2"
    assert body =~ "backoff_ms: 10"
  end
end
