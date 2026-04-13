defmodule SymphonyEx.Test.GitHubAdapterClientStub do
  @moduledoc false

  def request(request) do
    body =
      if to_string(request.url) == "https://api.github.com/graphql" do
        %{
          "data" => %{
            "organization" => %{
              "projectV2" => %{
                "id" => "PVT_x",
                "items" => %{
                  "nodes" => [
                    %{
                      "id" => "PVTI_active",
                      "content" => %{
                        "id" => "I_kwDOA1",
                        "number" => 12,
                        "title" => "Implement tracker abstraction",
                        "body" => "Need adapter",
                        "url" => "https://github.com/example/repo/issues/12",
                        "state" => "OPEN"
                      },
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
                    },
                    %{
                      "id" => "PVTI_done",
                      "content" => %{
                        "id" => "I_kwDOA1_done",
                        "number" => 13,
                        "title" => "Already done",
                        "body" => "Done body",
                        "url" => "https://github.com/example/repo/issues/13",
                        "state" => "OPEN"
                      },
                      "fieldValues" => %{
                        "nodes" => [
                          %{
                            "name" => "Done",
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
      else
        %{"message" => "Not Found"}
      end

    {:ok, %Req.Response{status: 200, body: body}}
  end
end

defmodule SymphonyEx.GitHub.AdapterTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.GitHub.Adapter
  alias SymphonyEx.Test.GitHubAdapterClientStub

  test "maps GitHub issue payload into tracker-agnostic issue struct" do
    payload = %{
      "id" => 101,
      "node_id" => "I_kwDOA1",
      "number" => 12,
      "title" => "Implement tracker abstraction",
      "body" => "Need adapter",
      "html_url" => "https://github.com/example/repo/issues/12",
      "state" => "open",
      "labels" => [%{"name" => "backend"}, %{"name" => "elixir"}]
    }

    assert %Issue{} = issue = Adapter.to_issue(payload)
    assert issue.identifier == "12"
    assert issue.labels == ["backend", "elixir"]
    assert issue.assignees == []
    assert issue.conflict_hints == []
    assert issue.state == "Open"
    assert issue.url == "https://github.com/example/repo/issues/12"
  end

  test "extracts assignees and conflict hints from GitHub issue payloads" do
    payload = %{
      "id" => 101,
      "number" => 12,
      "title" => "Implement tracker abstraction",
      "body" =>
        "Service: api\nPaths: lib/symphony_ex/orchestrator.ex, README.md\nRelease: 2026.03",
      "state" => "open",
      "assignees" => [%{"login" => "codex-bot"}, %{"login" => "reviewer-bot"}]
    }

    assert %Issue{} = issue = Adapter.to_issue(payload)
    assert issue.assignees == ["codex-bot", "reviewer-bot"]

    assert issue.conflict_hints == [
             "service:api",
             "path:lib/symphony_ex/orchestrator.ex",
             "path:readme.md",
             "release:2026.03"
           ]
  end

  test "fetches project-backed candidate issues using active status filtering" do
    opts = [
      api_key: "gh-token",
      owner: "example-org",
      repo: "repo",
      project_number: 7,
      active_states: ["Todo", "In Progress"],
      request_fun: &GitHubAdapterClientStub.request/1
    ]

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues(opts)
    assert issue.identifier == "12"
    assert issue.state == "Todo"
    assert issue.url == "https://github.com/example/repo/issues/12"
  end

  test "filters project-backed candidates by issue identifier" do
    opts = [
      api_key: "gh-token",
      owner: "example-org",
      repo: "repo",
      project_number: 7,
      active_states: ["Todo", "In Progress"],
      include_issue_identifiers: ["#13"],
      request_fun: &GitHubAdapterClientStub.request/1
    ]

    assert {:ok, []} = Adapter.fetch_candidate_issues(opts)
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

  test "writes run record into issue body via client-compatible request stub" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Open"
    }

    request_fun = fn request ->
      assert request.method == :patch
      assert String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12")

      body = request.options[:json][:body]

      if is_binary(body) do
        assert body =~ "issue: 12"
        assert body =~ "status: running"
      else
        assert request.options[:json][:state] == "open"
      end

      {:ok, %Req.Response{status: 200, body: Map.new(request.options[:json])}}
    end

    opts = [api_key: "gh-token", owner: "example", repo: "repo", request_fun: request_fun]

    assert {:ok, %{body: body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "<!-- symphony:managed -->"
  end

  test "maps orchestrator states to open or closed issue states" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "",
      state: "Open"
    }

    request_fun = fn request ->
      assert request.method == :patch
      {:ok, %Req.Response{status: 200, body: Map.new(request.options[:json])}}
    end

    opts = [api_key: "gh-token", owner: "example", repo: "repo", request_fun: request_fun]

    assert {:ok, %{state: "open"}} = Adapter.update_issue_state(issue, :running, opts)
    assert {:ok, %{state: "closed"}} = Adapter.update_issue_state(issue, :done, opts)
  end

  test "write_run_record adds configured labels and assignees for lifecycle states" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Todo"
    }

    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      cond do
        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "body" => request.options[:json][:body],
               "state" => request.options[:json][:state],
               "assignees" => request.options[:json][:assignees]
             }
           }}

        request.method == :post and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/labels") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [%{"name" => List.first(request.options[:json][:labels])}]
           }}

        true ->
          flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      write_back: [
        labels: ["symphony"],
        claimed: [labels: ["symphony:claimed"]],
        running: [labels: ["symphony:running"], assignees: ["codex-bot"]],
        released: [success: [labels: ["symphony:done"], assignees: ["reviewer-bot"]]]
      ],
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => running_body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert running_body =~ "status: running"
    running_requests = collect_requests(3)

    assert Enum.any?(running_requests, fn request ->
             request.method == :post and
               request.options[:json][:labels] == ["symphony", "symphony:running"]
           end)

    assert Enum.any?(running_requests, fn request ->
             request.method == :patch and request.options[:json][:assignees] == ["codex-bot"]
           end)

    assert {:ok, %{"body" => released_body}} =
             Adapter.write_run_record(
               issue,
               %{status: :released, attempt: 1, result: :success},
               opts
             )

    assert released_body =~ "result: success"
    released_requests = collect_requests(4)

    assert Enum.any?(released_requests, fn request ->
             request.method == :post and
               request.options[:json][:labels] == ["symphony", "symphony:done"]
           end)

    assert Enum.any?(released_requests, fn request ->
             request.method == :patch and request.options[:json][:assignees] == ["reviewer-bot"]
           end)
  end

  test "write_run_record can remove stale managed lifecycle labels before adding new ones" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Todo",
      labels: ["symphony", "symphony:claimed", "keep-me"]
    }

    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      cond do
        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "body" => request.options[:json][:body]
             }
           }}

        request.method == :delete and
            request.url.path == "/repos/example/repo/issues/12/labels/symphony:claimed" ->
          {:ok, %Req.Response{status: 200, body: %{}}}

        request.method == :post and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/labels") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [%{"name" => List.first(request.options[:json][:labels])}]
           }}

        true ->
          flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      write_back: [
        labels: ["symphony"],
        running: [labels: ["symphony:running"]],
        managed_label_prefixes: ["symphony:"]
      ],
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "status: running"
    requests = collect_requests(3)

    assert Enum.any?(requests, fn request ->
             request.method == :delete and
               request.url.path == "/repos/example/repo/issues/12/labels/symphony:claimed"
           end)

    assert Enum.any?(requests, fn request ->
             request.method == :post and
               request.options[:json][:labels] == ["symphony:running"]
           end)
  end

  test "write_run_record skips redundant lifecycle label/assignee/state automation when already satisfied" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Open",
      labels: ["symphony", "symphony:running"],
      assignees: ["codex-bot"]
    }

    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      if request.method == :patch and
           String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") and
           is_binary(request.options[:json][:body]) do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "body" => request.options[:json][:body]
           }
         }}
      else
        flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      write_back: [
        labels: ["symphony"],
        running: [labels: ["symphony:running"], assignees: ["codex-bot"]]
      ],
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "status: running"
    requests = collect_requests(1)
    assert [%{method: :patch}] = requests
  end

  test "write_run_record merges configured assignees with existing assignees by default" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Open",
      assignees: ["human-reviewer"]
    }

    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      if request.method == :patch and
           String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") do
        {:ok,
         %Req.Response{
           status: 200,
           body: %{
             "body" => request.options[:json][:body],
             "assignees" => request.options[:json][:assignees]
           }
         }}
      else
        flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      write_back: [running: [assignees: ["codex-bot"]]],
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "status: running"
    requests = collect_requests(2)

    assert Enum.any?(requests, fn request ->
             request.method == :patch and
               request.options[:json][:assignees] == ["human-reviewer", "codex-bot"]
           end)
  end

  test "write_run_record syncs issue/project lifecycle for in-progress and done states" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Todo"
    }

    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      cond do
        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "body" => request.options[:json][:body],
               "state" => request.options[:json][:state]
             }
           }}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_x",
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_x",
                           "content" => %{"number" => 12},
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
           }}

        to_string(request.url) == "https://api.github.com/graphql" and
            (String.contains?(request.options[:json]["query"], "mutation UpdateProjectStatus") or
               String.contains?(
                 request.options[:json]["query"],
                 "mutation UpdateProjectFieldValue"
               )) ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_x"}}
               }
             }
           }}
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      active_states: ["In Progress", "Todo"],
      terminal_states: ["Done"],
      write_back: [in_progress_state_names: ["In Progress"]],
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => running_body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert running_body =~ "status: running"
    running_requests = collect_requests(3)

    assert Enum.any?(running_requests, fn request ->
             request.method == :patch and is_binary(request.options[:json][:body]) and
               request.options[:json][:body] =~ "status: running"
           end)

    assert Enum.any?(running_requests, fn request ->
             String.contains?(request.options[:json]["query"] || "", "query ProjectItems")
           end)

    assert Enum.any?(running_requests, fn request ->
             request.options[:json]["variables"]["optionId"] == "opt_progress"
           end)

    assert {:ok, %{"body" => released_body}} =
             Adapter.write_run_record(
               issue,
               %{status: :released, attempt: 1, result: :success},
               opts
             )

    assert released_body =~ "result: success"
    released_requests = collect_requests(4)

    assert Enum.any?(released_requests, fn request ->
             request.method == :patch and request.options[:json][:state] == "closed"
           end)

    assert Enum.any?(released_requests, fn request ->
             String.contains?(request.options[:json]["query"] || "", "query ProjectItems")
           end)

    assert Enum.any?(released_requests, fn request ->
             request.options[:json]["variables"]["optionId"] == "opt_done"
           end)
  end

  test "write_run_record syncs configured project fields beyond status" do
    alias SymphonyEx.Orchestrator.Lifecycle

    lifecycle =
      Lifecycle.new(
        project_status_mapping: %{{:running, :any} => "In Progress"},
        project_field_mapping: %{
          {:running, :any} => %{
            "Owner" => "Codex",
            "Target Date" => "2026-04-01",
            "Effort" => 3,
            "Sprint" => "Sprint 2"
          }
        }
      )

    issue = %Issue{id: "I_2", identifier: "55", title: "Title", description: "", state: "Todo"}
    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      cond do
        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/55") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_fields",
                     "fields" => %{
                       "nodes" => [
                         %{
                           "id" => "status-field",
                           "name" => "Status",
                           "options" => [
                             %{"id" => "opt_progress", "name" => "In Progress"}
                           ]
                         },
                         %{"id" => "owner-field", "name" => "Owner", "dataType" => "TEXT"},
                         %{"id" => "date-field", "name" => "Target Date", "dataType" => "DATE"},
                         %{"id" => "number-field", "name" => "Effort", "dataType" => "NUMBER"},
                         %{
                           "id" => "iteration-field",
                           "name" => "Sprint",
                           "configuration" => %{
                             "iterations" => [
                               %{"id" => "iter-2", "title" => "Sprint 2"}
                             ]
                           }
                         }
                       ]
                     },
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_fields",
                           "content" => %{"number" => 55},
                           "fieldValues" => %{
                             "nodes" => [
                               %{
                                 "name" => "Todo",
                                 "field" => %{
                                   "id" => "status-field",
                                   "name" => "Status",
                                   "options" => [
                                     %{"id" => "opt_progress", "name" => "In Progress"}
                                   ]
                                 }
                               },
                               %{
                                 "text" => "Manual",
                                 "field" => %{"id" => "owner-field", "name" => "Owner"}
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
           }}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "mutation UpdateProject") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_fields"}}
               }
             }
           }}
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      lifecycle: lifecycle,
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "status: running"
    requests = collect_requests(8)

    assert Enum.any?(requests, fn request ->
             request.options[:json]["variables"]["optionId"] == "opt_progress"
           end)

    assert Enum.any?(requests, fn request ->
             request.options[:json]["variables"]["text"] == "Codex"
           end)

    assert Enum.any?(requests, fn request ->
             request.options[:json]["variables"]["date"] == "2026-04-01"
           end)

    assert Enum.any?(requests, fn request ->
             request.options[:json]["variables"]["number"] == 3.0
           end)

    assert Enum.any?(requests, fn request ->
             request.options[:json]["variables"]["iterationId"] == "iter-2"
           end)
  end

  test "write_run_record ignores unsupported nested project field values" do
    alias SymphonyEx.Orchestrator.Lifecycle

    lifecycle =
      Lifecycle.new(
        project_status_mapping: %{{:running, :any} => "In Progress"},
        project_field_mapping: %{
          {:running, :any} => %{
            "Owner" => "Codex",
            "metadata" => %{"status" => "Ready"},
            "attempts" => [1, 2]
          }
        }
      )

    assert Lifecycle.resolve_project_fields(lifecycle, :running, nil) == %{"Owner" => "Codex"}

    issue = %Issue{id: "I_3", identifier: "56", title: "Title", description: "", state: "Todo"}
    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      cond do
        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/56") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_fields",
                     "fields" => %{
                       "nodes" => [
                         %{
                           "id" => "status-field",
                           "name" => "Status",
                           "options" => [
                             %{"id" => "opt_progress", "name" => "In Progress"}
                           ]
                         },
                         %{"id" => "owner-field", "name" => "Owner", "dataType" => "TEXT"}
                       ]
                     },
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_fields",
                           "content" => %{"number" => 56},
                           "fieldValues" => %{
                             "nodes" => [
                               %{
                                 "name" => "Todo",
                                 "field" => %{
                                   "id" => "status-field",
                                   "name" => "Status",
                                   "options" => [
                                     %{"id" => "opt_progress", "name" => "In Progress"}
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
           }}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "mutation UpdateProject") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "updateProjectV2ItemFieldValue" => %{"projectV2Item" => %{"id" => "PVTI_fields"}}
               }
             }
           }}
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      lifecycle: lifecycle,
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "status: running"
    requests = collect_requests(5)

    project_updates =
      Enum.filter(requests, fn request ->
        to_string(request.url) == "https://api.github.com/graphql" and
          String.contains?(request.options[:json]["query"], "mutation UpdateProject")
      end)

    assert Enum.count(project_updates) == 2

    assert Enum.any?(project_updates, fn request ->
             request.options[:json]["variables"]["optionId"] == "opt_progress"
           end)

    assert Enum.any?(project_updates, fn request ->
             request.options[:json]["variables"]["text"] == "Codex"
           end)
  end

  describe "lifecycle config interop" do
    test "custom lifecycle mapping drives actual issue state and project option payloads" do
      alias SymphonyEx.Orchestrator.Lifecycle

      custom =
        Lifecycle.new(
          issue_state_mapping: %{
            {:released, :success} => :open,
            {:released, :failed} => :closed
          },
          project_status_mapping: %{
            {:claimed, :any} => "Working",
            {:running, :any} => "Working",
            {:retry_queued, :any} => "Blocked",
            {:released, :success} => "Shipped",
            {:released, :failed} => "Cancelled"
          }
        )

      issue = %Issue{
        id: "I_1",
        identifier: "99",
        title: "Title",
        description: "",
        state: "Open"
      }

      parent = self()

      request_fun = fn request ->
        send(parent, {:github_request, request})

        cond do
          request.method == :patch and
              String.ends_with?(to_string(request.url), "/repos/example/repo/issues/99") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "body" => request.options[:json][:body],
                 "state" => request.options[:json][:state]
               }
             }}

          to_string(request.url) == "https://api.github.com/graphql" and
              String.contains?(request.options[:json]["query"], "query ProjectItems") ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "data" => %{
                   "organization" => %{
                     "projectV2" => %{
                       "id" => "PVT_custom",
                       "items" => %{
                         "nodes" => [
                           %{
                             "id" => "PVTI_custom",
                             "content" => %{"number" => 99},
                             "fieldValues" => %{
                               "nodes" => [
                                 %{
                                   "name" => "Todo",
                                   "field" => %{
                                     "id" => "status-field",
                                     "name" => "Status",
                                     "options" => [
                                       %{"id" => "opt_working", "name" => "Working"},
                                       %{"id" => "opt_blocked", "name" => "Blocked"},
                                       %{"id" => "opt_shipped", "name" => "Shipped"},
                                       %{"id" => "opt_cancelled", "name" => "Cancelled"}
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
             }}

          to_string(request.url) == "https://api.github.com/graphql" and
              (String.contains?(request.options[:json]["query"], "mutation UpdateProjectStatus") or
                 String.contains?(
                   request.options[:json]["query"],
                   "mutation UpdateProjectFieldValue"
                 )) ->
            {:ok,
             %Req.Response{
               status: 200,
               body: %{
                 "data" => %{
                   "updateProjectV2ItemFieldValue" => %{
                     "projectV2Item" => %{"id" => "PVTI_custom"}
                   }
                 }
               }
             }}
        end
      end

      opts = [
        api_key: "gh-token",
        owner: "example",
        repo: "repo",
        project_number: 7,
        lifecycle: custom,
        request_fun: request_fun
      ]

      assert {:ok, %{"body" => success_body}} =
               Adapter.write_run_record(
                 issue,
                 %{status: :released, attempt: 1, result: :success},
                 opts
               )

      assert success_body =~ "result: success"
      success_requests = collect_requests(3)

      assert Enum.any?(success_requests, fn request ->
               request.method == :patch and is_binary(request.options[:json][:body])
             end)

      refute Enum.any?(success_requests, fn request ->
               request.method == :patch and request.options[:json][:state] == "open"
             end)

      assert Enum.any?(success_requests, fn request ->
               request.options[:json]["variables"]["optionId"] == "opt_shipped"
             end)

      assert {:ok, %{"body" => failed_body}} =
               Adapter.write_run_record(
                 issue,
                 %{status: :released, attempt: 2, result: :failed},
                 opts
               )

      assert failed_body =~ "result: failed"
      failed_requests = collect_requests(4)

      assert Enum.any?(failed_requests, fn request ->
               request.method == :patch and request.options[:json][:state] == "closed"
             end)

      assert Enum.any?(failed_requests, fn request ->
               request.options[:json]["variables"]["optionId"] == "opt_cancelled"
             end)
    end

    test "default lifecycle keeps backward-compatible semantics" do
      alias SymphonyEx.Orchestrator.Lifecycle

      lc = Lifecycle.default()

      assert Lifecycle.resolve_issue_state(lc, :claimed, nil) == :open
      assert Lifecycle.resolve_issue_state(lc, :running, nil) == :open
      assert Lifecycle.resolve_issue_state(lc, :released, :success) == :closed
      assert Lifecycle.resolve_issue_state(lc, :released, :failed) == :open

      assert Lifecycle.resolve_project_status(lc, :claimed, nil) == "In Progress"
      assert Lifecycle.resolve_project_status(lc, :running, nil) == "In Progress"
      assert Lifecycle.resolve_project_status(lc, :retry_queued, nil) == "Todo"
      assert Lifecycle.resolve_project_status(lc, :released, :success) == "Done"
      assert Lifecycle.resolve_project_status(lc, :released, :failed) == "Todo"
    end
  end

  test "write_run_record annotates partial write-back when project status sync fails" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Todo"
    }

    parent = self()

    request_fun = fn request ->
      send(parent, {:github_request, request})

      cond do
        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_x",
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_x",
                           "content" => %{"number" => 12},
                           "fieldValues" => %{
                             "nodes" => [
                               %{
                                 "name" => "Todo",
                                 "field" => %{
                                   "id" => "status-field",
                                   "name" => "Status",
                                   "options" => [
                                     %{"id" => "opt_progress", "name" => "In Progress"}
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
           }}

        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "mutation UpdateProject") ->
          {:error, :project_status_down}

        true ->
          flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      active_states: ["In Progress", "Todo"],
      terminal_states: ["Done"],
      write_back: [in_progress_state_names: ["In Progress"]],
      request_fun: request_fun
    ]

    assert {:error, {:partial_write_back, :project_status_failed, :project_status_down}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    requests = collect_requests(4)

    patch_bodies =
      requests
      |> Enum.filter(fn request ->
        request.method == :patch and is_binary(request.options[:json][:body])
      end)
      |> Enum.map(& &1.options[:json][:body])

    assert Enum.count(patch_bodies) == 2
    assert Enum.at(patch_bodies, 0) =~ "status: running"
    assert Enum.at(patch_bodies, 1) =~ "partial_write_back: true"
    assert Enum.at(patch_bodies, 1) =~ "partial_write_back_stage: project_status_failed"
    assert Enum.at(patch_bodies, 1) =~ "partial_write_back_reason: :project_status_down"
  end

  defp collect_requests(count, acc \\ [])
  defp collect_requests(0, acc), do: Enum.reverse(acc)

  defp collect_requests(count, acc) do
    assert_receive {:github_request, request}
    collect_requests(count - 1, [request | acc])
  end
end
