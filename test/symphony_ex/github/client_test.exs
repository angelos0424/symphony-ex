defmodule SymphonyEx.Test.GitHubClientStub do
  @moduledoc false

  def request(request) do
    send(self(), {:github_request, request})
    body = route_request(request)
    {:ok, %Req.Response{status: 200, body: body}}
  end

  defp route_request(request) do
    url = to_string(request.url)
    route_by_method(request.method, url, request)
  end

  defp route_by_method(:get, url, _request) do
    cond do
      String.ends_with?(url, "/issues") -> issues_list_response()
      String.contains?(url, "/issues/12/comments") -> [%{"id" => 201, "body" => "first"}]
      true -> %{"message" => "Not Found"}
    end
  end

  defp route_by_method(:post, url, request) do
    cond do
      String.contains?(url, "/issues/12/comments") ->
        %{"id" => 202, "body" => request.options[:json][:body]}

      url == "https://api.github.com/graphql" ->
        route_graphql(request)

      true ->
        %{"message" => "Not Found"}
    end
  end

  defp route_by_method(:patch, url, request) do
    if String.contains?(url, "/issues/12") do
      Map.new(request.options[:json])
    else
      %{"message" => "Not Found"}
    end
  end

  defp route_by_method(_method, _url, _request), do: %{"message" => "Not Found"}

  defp route_graphql(request) do
    query = request.options[:json]["query"]

    if String.contains?(query, "query ProjectItems") do
      project_items_response()
    else
      graphql_mutation_response(request)
    end
  end

  defp issues_list_response do
    [
      %{
        "id" => 101,
        "node_id" => "I_kwDOA1",
        "number" => 12,
        "title" => "Implement GitHub client",
        "body" => "Need REST issue client",
        "html_url" => "https://github.com/example/repo/issues/12",
        "state" => "open",
        "labels" => [%{"name" => "backend"}]
      },
      %{
        "id" => 102,
        "number" => 99,
        "title" => "Ignore PR",
        "state" => "open",
        "pull_request" => %{"url" => "https://api.github.com/repos/example/repo/pulls/99"}
      }
    ]
  end

  defp project_items_response do
    %{
      "data" => %{
        "organization" => %{
          "projectV2" => %{
            "id" => "PVT_x",
            "fields" => %{
              "nodes" => [
                %{
                  "id" => "status-field",
                  "name" => "Status",
                  "options" => [
                    %{"id" => "opt_todo", "name" => "Todo"},
                    %{"id" => "opt_progress", "name" => "In Progress"},
                    %{"id" => "opt_done", "name" => "Done"}
                  ]
                },
                %{"id" => "text-field", "name" => "Owner", "dataType" => "TEXT"}
              ]
            },
            "items" => %{
              "nodes" => [
                %{
                  "id" => "PVTI_x",
                  "content" => %{"number" => 12, "title" => "Implement GitHub client"},
                  "fieldValues" => %{
                    "nodes" => [
                      %{
                        "name" => "Todo",
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
  end

  defp graphql_mutation_response(request) do
    %{
      "data" => %{
        "updateProjectV2ItemFieldValue" => %{
          "projectV2Item" => %{"id" => request.options[:json]["variables"]["itemId"]}
        }
      }
    }
  end
end

defmodule SymphonyEx.GitHub.ClientTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.GitHub.Client
  alias SymphonyEx.Test.GitHubClientStub

  test "lists open GitHub issues and filters out pull requests" do
    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, [issue]} = Client.fetch_candidate_issues(opts)
    assert issue["number"] == 12

    assert_received {:github_request, request}
    assert to_string(request.url) == "https://api.github.com/repos/example/repo/issues"
    assert request.method == :get
    assert request.headers["authorization"] == ["Bearer gh-token"]
    assert request.options[:params][:state] == "open"
  end

  test "filters candidate issues by include_issue_identifiers" do
    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      include_issue_identifiers: ["#12"],
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, [issue]} = Client.fetch_candidate_issues(opts)
    assert issue["number"] == 12
  end

  test "creates an issue comment via REST" do
    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, %{"body" => "hello"}} = Client.create_issue_comment("12", "hello", opts)

    assert_received {:github_request, request}
    assert request.method == :post
    assert request.options[:json] == %{body: "hello"}
  end

  test "updates an issue body via REST" do
    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, %{body: "updated"}} = Client.update_issue_body(12, "updated", opts)

    assert_received {:github_request, request}
    assert request.method == :patch
    assert request.options[:json] == %{body: "updated"}
  end

  test "lists project items via GraphQL" do
    opts = [
      api_key: "gh-token",
      owner: "example-org",
      project_number: 7,
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, [item]} = Client.list_project_items(opts)
    assert item["content"]["number"] == 12
    assert Enum.any?(item["projectFields"], &(&1["name"] == "Owner"))

    assert_received {:github_request, request}
    assert to_string(request.url) == "https://api.github.com/graphql"
    assert request.method == :post
    assert request.options[:json]["variables"] == %{"owner" => "example-org", "number" => 7}
  end

  test "lists user-owned project items when organization lookup returns a benign partial error" do
    request_fun = fn request ->
      send(self(), {:github_request, request})

      body = %{
        "data" => %{
          "organization" => nil,
          "user" => %{
            "projectV2" => %{
              "id" => "PVT_user",
              "fields" => %{
                "nodes" => [
                  %{
                    "id" => "status-field",
                    "name" => "Status",
                    "options" => [
                      %{"id" => "opt_todo", "name" => "Todo"}
                    ]
                  }
                ]
              },
              "items" => %{
                "nodes" => [
                  %{
                    "id" => "PVTI_user",
                    "content" => %{"number" => 42, "title" => "User project issue"},
                    "fieldValues" => %{
                      "nodes" => [
                        %{
                          "name" => "Todo",
                          "field" => %{
                            "id" => "status-field",
                            "name" => "Status",
                            "options" => [
                              %{"id" => "opt_todo", "name" => "Todo"}
                            ]
                          }
                        }
                      ]
                    }
                  }
                ]
              }
            }
          }
        },
        "errors" => [
          %{
            "message" => "Could not resolve to an Organization with the login of 'example-user'.",
            "path" => ["organization"],
            "type" => "NOT_FOUND"
          }
        ]
      }

      {:ok, %Req.Response{status: 200, body: body}}
    end

    opts = [
      api_key: "gh-token",
      owner: "example-user",
      project_number: 3,
      request_fun: request_fun
    ]

    assert {:ok, [item]} = Client.list_project_items(opts)
    assert item["id"] == "PVTI_user"
    assert item["content"]["number"] == 42
  end

  test "updates project status via GraphQL mutation" do
    opts = [
      api_key: "gh-token",
      owner: "example-org",
      status_field_id: "unused",
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_x"}}}} =
             Client.update_project_status("PVT_x", "PVTI_x", "status-field", "opt_done", opts)

    assert_received {:github_request, request}
    assert to_string(request.url) == "https://api.github.com/graphql"
    assert request.method == :post

    assert request.options[:json]["variables"] == %{
             "projectId" => "PVT_x",
             "itemId" => "PVTI_x",
             "fieldId" => "status-field",
             "optionId" => "opt_done"
           }
  end

  test "updates generic project field values via GraphQL mutation" do
    opts = [
      api_key: "gh-token",
      owner: "example-org",
      request_fun: &GitHubClientStub.request/1
    ]

    assert {:ok, %{"updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_x"}}}} =
             Client.update_project_field_value(
               "PVT_x",
               "PVTI_x",
               "text-field",
               %{text: "Codex"},
               opts
             )

    assert_received {:github_request, request}
    assert to_string(request.url) == "https://api.github.com/graphql"
    assert request.method == :post
    assert request.options[:json]["variables"]["text"] == "Codex"
  end
end
