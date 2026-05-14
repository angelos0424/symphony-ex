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
                                %{"id" => "opt_review", "name" => "In Review"},
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

  test "extracts assignees, conflict hints, and explicit branch metadata from GitHub issue payloads" do
    payload = %{
      "id" => 101,
      "number" => 12,
      "title" => "Implement tracker abstraction",
      "body" =>
        "Service: api\nPaths: lib/symphony_ex/orchestrator.ex, README.md\nRelease: 2026.03\nTarget-Branch: codex/issue-14-design-audit-apply\nTarget-PR: 19",
      "state" => "open",
      "assignees" => [%{"login" => "codex-bot"}, %{"login" => "reviewer-bot"}]
    }

    assert %Issue{} = issue = Adapter.to_issue(payload)
    assert issue.assignees == ["codex-bot", "reviewer-bot"]
    assert issue.target_branch == "codex/issue-14-design-audit-apply"
    assert issue.target_pr == 19

    assert issue.conflict_hints == [
             "service:api",
             "path:lib/symphony_ex/orchestrator.ex",
             "path:readme.md",
             "release:2026.03"
           ]
  end

  test "resolves target branch from existing pr metadata when branch is omitted" do
    payload = %{
      "id" => 101,
      "number" => 12,
      "title" => "Implement tracker abstraction",
      "body" =>
        "Service: api\nPaths: lib/symphony_ex/orchestrator.ex\nExisting PR: https://github.com/example/repo/pull/19",
      "state" => "open"
    }

    request_fun = fn request ->
      case {request.method, to_string(request.url)} do
        {:get, "https://api.github.com/repos/example/repo/pulls/19"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "number" => 19,
               "head" => %{"ref" => "codex/issue-14-design-audit-apply"}
             }
           }}

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end

    issue =
      Adapter.to_issue(payload,
        api_key: "gh-token",
        owner: "example",
        repo: "repo",
        request_fun: request_fun
      )

    assert issue.target_pr == 19
    assert issue.target_branch == "codex/issue-14-design-audit-apply"
  end

  test "fetch_issue_by_identifier enriches issues with blocking dependency identifiers" do
    request_fun = fn request ->
      case {request.method, to_string(request.url)} do
        {:get, "https://api.github.com/repos/example/repo/issues/12"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "id" => 101,
               "number" => 12,
               "title" => "Implement tracker abstraction",
               "body" => "Service: api\nPaths: lib/symphony_ex/orchestrator.ex",
               "state" => "open"
             }
           }}

        {:get, "https://api.github.com/repos/example/repo/issues/12/dependencies/blocked_by"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{"number" => 41, "state" => "open"},
               %{"number" => 42, "state" => "closed"}
             ]
           }}

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end

    opts = [api_key: "gh-token", owner: "example", repo: "repo", request_fun: request_fun]

    assert {:ok, %Issue{} = issue} = Adapter.fetch_issue_by_identifier("12", opts)
    assert issue.blocked_by_identifiers == ["41"]
    assert issue.missing_required_fields == []
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

  test "includes In Review issues with unprocessed @Task comments as review follow-up candidates" do
    request_fun = fn request ->
      case {request.method, to_string(request.url)} do
        {:post, "https://api.github.com/graphql"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_123",
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_123",
                           "content" => %{
                             "id" => "I_12",
                             "number" => 12,
                             "title" => "Review project analysis",
                             "body" =>
                               "Service: docs\nPaths: .review/2026-04-24.md\nTarget-PR: 3\nTarget-Branch: codex/review-doc\n",
                             "url" => "https://github.com/example/repo/issues/12",
                             "state" => "OPEN"
                           },
                           "fieldValues" => %{
                             "nodes" => [
                               %{
                                 "name" => "In Review",
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
           }}

        {:get, "https://api.github.com/repos/example/repo/issues/12/comments"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{
                 "id" => 1001,
                 "user" => %{"login" => "reviewer"},
                 "body" => "@Task\n실행 방법을 더 명확히 적어줘.",
                 "html_url" => "https://github.com/example/repo/issues/12#issuecomment-1001"
               }
             ]
           }}

        {:get, "https://api.github.com/repos/example/repo/issues/3/comments"} ->
          {:ok, %Req.Response{status: 200, body: []}}

        {:get, "https://api.github.com/repos/example/repo/pulls/3/comments"} ->
          {:ok, %Req.Response{status: 200, body: []}}

        {:post, "https://api.github.com/repos/example/repo/issues/comments/1001/reactions"} ->
          {:ok,
           %Req.Response{status: 201, body: %{"content" => request.options[:json][:content]}}}

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      active_states: ["Todo", "In Progress"],
      review_task_states: ["In Review"],
      request_fun: request_fun
    ]

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues(opts)
    assert issue.identifier == "12"
    assert issue.state == "In Progress"
    assert issue.target_pr == 3
    assert issue.target_branch == "codex/review-doc"
    assert issue.review_task_ids == ["issue-comment:1001"]
    assert "symphony:review-task" in issue.labels
    assert issue.description =~ "## Review Follow-up Task"
    assert issue.description =~ "실행 방법을 더 명확히 적어줘."
    assert issue.description =~ "Do not create a new PR"
  end

  test "includes In Review issues with issue @Task comments even when no PR exists" do
    request_fun = fn request ->
      case {request.method, to_string(request.url)} do
        {:post, "https://api.github.com/graphql"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_123",
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_123",
                           "content" => %{
                             "id" => "I_12",
                             "number" => 12,
                             "title" => "Review planning note",
                             "body" => "Service: docs\nPaths: docs/plan.md\n",
                             "url" => "https://github.com/example/repo/issues/12",
                             "state" => "OPEN"
                           },
                           "fieldValues" => %{
                             "nodes" => [
                               %{
                                 "name" => "In Review",
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
           }}

        {:get, "https://api.github.com/repos/example/repo/issues/12/comments"} ->
          {:ok,
           %Req.Response{
             status: 200,
             body: [
               %{
                 "id" => 2001,
                 "user" => %{"login" => "reviewer"},
                 "body" => "@Task pr\n필요하면 PR까지 만들어줘.",
                 "html_url" => "https://github.com/example/repo/issues/12#issuecomment-2001"
               }
             ]
           }}

        {:post, "https://api.github.com/repos/example/repo/issues/comments/2001/reactions"} ->
          {:ok,
           %Req.Response{status: 201, body: %{"content" => request.options[:json][:content]}}}

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      active_states: ["Todo", "In Progress"],
      review_task_states: ["In Review"],
      request_fun: request_fun
    ]

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues(opts)
    assert issue.identifier == "12"
    assert issue.target_pr == nil
    assert issue.target_branch == nil
    assert issue.review_task_ids == ["issue-comment:2001"]
    assert "symphony:review-task" in issue.labels
    assert issue.description =~ "## Issue Follow-up Task"
    assert issue.description =~ "필요하면 PR까지 만들어줘."

    assert issue.description =~
             "Do not create a PR unless an explicit `@Task pr` command asks for one."
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

  test "keeps active project items dispatchable even when issue body contains stale terminal status block" do
    request_fun = fn request ->
      cond do
        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_123",
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_123",
                           "content" => %{
                             "number" => 14,
                             "title" => "Issue 14",
                             "body" =>
                               "Service: orchestration\nPaths: lib/symphony_ex/orchestrator.ex\n\n<!-- symphony:status -->\n## Symphony Status\n- Final status: in_review\n- Pull request: none\n<!-- /symphony:status -->",
                             "url" => "https://github.com/example/repo/issues/14",
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
           }}

        true ->
          flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example-org",
      repo: "repo",
      project_number: 7,
      active_states: ["Todo", "In Progress"],
      request_fun: request_fun
    ]

    assert {:ok, [issue]} = Adapter.fetch_candidate_issues(opts)
    assert issue.identifier == "14"
    assert issue.state == "Todo"
  end

  test "skips rerun candidates without project status when issue body already indicates PR-created final state" do
    request_fun = fn request ->
      cond do
        to_string(request.url) == "https://api.github.com/graphql" and
            String.contains?(request.options[:json]["query"], "query ProjectItems") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "data" => %{
                 "organization" => %{
                   "projectV2" => %{
                     "id" => "PVT_123",
                     "items" => %{
                       "nodes" => [
                         %{
                           "id" => "PVTI_123",
                           "content" => %{
                             "number" => 15,
                             "title" => "Issue 15",
                             "body" =>
                               "<!-- symphony:status -->\n## Symphony Status\n- Final status: pr_created\n- Pull request: PR #17 https://github.com/example/repo/pull/17\n<!-- /symphony:status -->"
                           },
                           "fieldValues" => %{"nodes" => []}
                         }
                       ]
                     }
                   }
                 },
                 "user" => nil
               }
             }
           }}

        true ->
          flunk("unexpected request: #{inspect(request.method)} #{inspect(request.url)}")
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example-org",
      repo: "repo",
      project_number: 7,
      active_states: ["Todo", "In Progress"],
      request_fun: request_fun
    ]

    assert {:ok, []} = Adapter.fetch_candidate_issues(opts)
  end

  test "wraps managed run record block" do
    _description = "Existing notes"

    wrapped = Adapter.managed_block("run status: claimed")

    assert wrapped =~ "<!-- symphony:managed -->"
    assert wrapped =~ "run status: claimed"

    replaced = Adapter.managed_block("run status: running")

    assert replaced =~ "run status: running"
    refute replaced =~ "run status: claimed"
  end

  test "writes run record into an issue comment via client-compatible request stub" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Open"
    }

    request_fun = fn request ->
      assert request.method == :post
      assert String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/comments")

      body = request.options[:json][:body]
      assert body =~ "<!-- symphony:managed -->"
      assert body =~ "issue: 12"
      assert body =~ "status: running"

      {:ok, %Req.Response{status: 200, body: Map.new(request.options[:json])}}
    end

    opts = [api_key: "gh-token", owner: "example", repo: "repo", request_fun: request_fun]

    assert {:ok, %{body: body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "<!-- symphony:managed -->"
  end

  test "write_run_record updates issue body summary with PR number and keeps PR URL in metadata" do
    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "14",
      title: "Title",
      description:
        "Original body\n\nService: docs\nPaths: .review/2026-04-24.md\nTarget-Branch: main",
      state: "Open",
      target_branch: "main"
    }

    request_fun = fn request ->
      case {request.method, to_string(request.url)} do
        {:post, url} ->
          if String.ends_with?(url, "/repos/example/repo/issues/14/comments") do
            {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}
          else
            flunk("unexpected post #{url}")
          end

        {:get, url} ->
          cond do
            String.ends_with?(url, "/repos/example/repo/issues/14") ->
              {:ok,
               %Req.Response{
                 status: 200,
                 body: %{
                   "number" => 14,
                   "body" =>
                     "Original body\n\nService: docs\nPaths: .review/2026-04-24.md\nTarget-Branch: main"
                 }
               }}

            String.ends_with?(url, "/repos/example/repo/pulls") ->
              {:ok,
               %Req.Response{
                 status: 200,
                 body: [
                   %{
                     "number" => 17,
                     "html_url" => "https://github.com/example/repo/pull/17",
                     "body" => "Fixes #14",
                     "head" => %{"ref" => "codex/issue-14-design-polish"}
                   }
                 ]
               }}

            true ->
              flunk("unexpected get #{url}")
          end

        {:patch, url} ->
          if String.ends_with?(url, "/repos/example/repo/issues/14") do
            body = request.options[:json][:body]
            assert body =~ "## Symphony Status"
            assert body =~ "- Final status: pr_created"
            assert body =~ "- Pull request: PR #17"
            refute body =~ "- Pull request: PR #17 https://github.com/example/repo/pull/17"
            assert body =~ "Target-PR: 17"
            assert body =~ "Target-Branch: codex/issue-14-design-polish"
            assert body =~ "Existing PR: https://github.com/example/repo/pull/17"
            refute body =~ "Target-Branch: main"
            {:ok, %Req.Response{status: 200, body: %{"body" => body}}}
          else
            flunk("unexpected patch #{url}")
          end
      end
    end

    opts = [api_key: "gh-token", owner: "example", repo: "repo", request_fun: request_fun]

    assert {:ok, _response} =
             Adapter.write_run_record(
               issue,
               %{status: :released, attempt: 3, result: :success},
               opts
             )
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
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{status: 200, body: %{"number" => 99, "body" => "Latest issue body"}}}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/pulls") ->
          {:ok, %Req.Response{status: 200, body: []}}

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
    released_requests = collect_requests(6)

    assert Enum.any?(released_requests, fn request ->
             request.method == :patch and
               String.contains?(request.options[:json][:body] || "", "- Final status: in_review") and
               String.contains?(request.options[:json][:body] || "", "- Pull request: none")
           end)

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
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

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

      cond do
        request.method == :post and
          String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/comments") and
            is_binary(request.options[:json][:body]) ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "body" => request.options[:json][:body]
             }
           }}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/pulls") ->
          {:ok, %Req.Response{status: 200, body: []}}

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
        running: [labels: ["symphony:running"], assignees: ["codex-bot"]]
      ],
      request_fun: request_fun
    ]

    assert {:ok, %{"body" => body}} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert body =~ "status: running"
    requests = collect_requests(1)
    assert [%{method: :post}] = requests
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

      cond do
        request.method == :post and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/comments") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "body" => request.options[:json][:body]
             }
           }}

        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "assignees" => request.options[:json][:assignees]
             }
           }}

        true ->
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

  test "does not roll project status back from Done to In Progress" do
    issue = %Issue{
      id: "I_rollback",
      identifier: "14",
      title: "Title",
      description: "",
      state: "Open"
    }

    request_fun = fn request ->
      cond do
        request.method == :post and String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/14") ->
          {:ok, %Req.Response{status: 200, body: %{"number" => 14, "body" => "Original body"}}}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/pulls") ->
          {:ok, %Req.Response{status: 200, body: []}}

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
                           "content" => %{"number" => 14},
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
           }}

        to_string(request.url) == "https://api.github.com/graphql" and
            (String.contains?(request.options[:json]["query"], "mutation UpdateProjectStatus") or
               String.contains?(
                 request.options[:json]["query"],
                 "mutation UpdateProjectFieldValue"
               )) ->
          flunk("project status should not be downgraded")

        request.method == :patch and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/14") ->
          {:ok,
           %Req.Response{
             status: 200,
             body: %{
               "body" => request.options[:json][:body],
               "state" => request.options[:json][:state]
             }
           }}

        true ->
          {:ok, %Req.Response{status: 200, body: %{}}}
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

    assert {:ok, _response} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)
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
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

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

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{status: 200, body: %{"number" => 12, "body" => "Latest issue body"}}}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12") ->
          {:ok,
           %Req.Response{status: 200, body: %{"number" => 12, "body" => "Latest issue body"}}}

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
           }}

        request.method == :get and
            String.ends_with?(to_string(request.url), "/repos/example/repo/pulls") ->
          {:ok, %Req.Response{status: 200, body: []}}

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
             request.method == :post and is_binary(request.options[:json][:body]) and
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
    released_requests = collect_requests(6)

    assert Enum.any?(released_requests, fn request ->
             request.method == :get and
               String.ends_with?(to_string(request.url), "/repos/example/repo/pulls")
           end)

    assert Enum.any?(released_requests, fn request ->
             request.options[:json]["variables"]["optionId"] == "opt_review"
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
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

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
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

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
          request.method == :post and
              String.contains?(to_string(request.url), "/comments") ->
            {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

          request.method == :get and
              String.ends_with?(to_string(request.url), "/repos/example/repo/pulls") ->
            {:ok, %Req.Response{status: 200, body: []}}

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

          request.method == :get and
              String.ends_with?(to_string(request.url), "/repos/example/repo/issues/99") ->
            {:ok,
             %Req.Response{status: 200, body: %{"number" => 12, "body" => "Latest issue body"}}}

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
      success_requests = collect_requests(6)

      assert Enum.any?(success_requests, fn request ->
               request.method == :post and is_binary(request.options[:json][:body])
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
               request.method == :post and is_binary(request.options[:json][:body])
             end)

      assert Enum.any?(failed_requests, fn request ->
               request.method == :patch and request.options[:json][:state] == "closed"
             end)
    end

    test "default lifecycle routes successful runs into review" do
      alias SymphonyEx.Orchestrator.Lifecycle

      lc = Lifecycle.default()

      assert Lifecycle.resolve_issue_state(lc, :claimed, nil) == :open
      assert Lifecycle.resolve_issue_state(lc, :running, nil) == :open
      assert Lifecycle.resolve_issue_state(lc, :released, :success) == :open
      assert Lifecycle.resolve_issue_state(lc, :released, :failed) == :open

      assert Lifecycle.resolve_project_status(lc, :claimed, nil) == "In Progress"
      assert Lifecycle.resolve_project_status(lc, :running, nil) == "In Progress"
      assert Lifecycle.resolve_project_status(lc, :retry_queued, nil) == "Todo"
      assert Lifecycle.resolve_project_status(lc, :released, :success) == "In Review"
      assert Lifecycle.resolve_project_status(lc, :released, :failed) == "In Review"
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
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

        request.method == :post and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/comments") ->
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

    comment_bodies =
      requests
      |> Enum.filter(fn request ->
        request.method == :post and is_binary(request.options[:json][:body])
      end)
      |> Enum.map(& &1.options[:json][:body])

    assert Enum.count(comment_bodies) == 2
    assert Enum.at(comment_bodies, 0) =~ "status: running"
    assert Enum.at(comment_bodies, 1) =~ "partial_write_back: true"
    assert Enum.at(comment_bodies, 1) =~ "partial_write_back_stage: project_status_failed"
    assert Enum.at(comment_bodies, 1) =~ "partial_write_back_reason: :project_status_down"
  end

  test "write_run_record emits stage telemetry for successful sync" do
    test_pid = self()

    handler_id = "adapter-stage-success-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:symphony_ex, :write_back, :stage]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Todo",
      labels: [],
      assignees: []
    }

    request_fun = fn request ->
      cond do
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

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
                           "projectId" => "PVT_x",
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
          {:ok,
           %Req.Response{
             status: 200,
             body: %{"data" => %{"updateProjectV2ItemFieldValue" => %{}}}
           }}

        true ->
          {:ok, %Req.Response{status: 200, body: %{}}}
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

    assert {:ok, _response} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{stage: :managed_record, outcome: :success, tracker_kind: :github}}

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{stage: :essential, outcome: :success, tracker_kind: :github}}

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{stage: :optional, outcome: :success, tracker_kind: :github}}
  end

  test "write_run_record emits stage telemetry for partial optional failure" do
    test_pid = self()

    handler_id = "adapter-stage-partial-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:symphony_ex, :write_back, :stage]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    issue = %Issue{
      id: "I_kwDOA1",
      identifier: "12",
      title: "Title",
      description: "Original",
      state: "Todo",
      labels: [],
      assignees: []
    }

    request_fun = fn request ->
      cond do
        request.method == :post and
            String.contains?(to_string(request.url), "/comments") ->
          {:ok, %Req.Response{status: 200, body: %{"body" => request.options[:json][:body]}}}

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
                           "projectId" => "PVT_x",
                           "content" => %{"number" => 12},
                           "fieldValues" => %{
                             "nodes" => [
                               %{
                                 "name" => "In Progress",
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

        request.method == :post and
            String.ends_with?(to_string(request.url), "/repos/example/repo/issues/12/labels") ->
          {:error, :labels_down}

        true ->
          {:ok, %Req.Response{status: 200, body: %{}}}
      end
    end

    opts = [
      api_key: "gh-token",
      owner: "example",
      repo: "repo",
      project_number: 7,
      active_states: ["In Progress", "Todo"],
      terminal_states: ["Done"],
      write_back: [
        enabled: true,
        in_progress_state_names: ["In Progress"],
        labels: ["symphony"],
        running: [labels: ["agent:active"]]
      ],
      request_fun: request_fun
    ]

    assert {:ok, _response} =
             Adapter.write_run_record(issue, %{status: :running, attempt: 1}, opts)

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{stage: :managed_record, outcome: :success, tracker_kind: :github}}

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{stage: :essential, outcome: :success, tracker_kind: :github}}

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{
                      stage: :optional,
                      outcome: :partial,
                      failed_stage: :label_sync_failed,
                      tracker_kind: :github
                    }}

    assert_receive {:telemetry_event, [:symphony_ex, :write_back, :stage], _measurements,
                    %{
                      stage: :annotation,
                      outcome: :success,
                      failed_stage: :label_sync_failed,
                      tracker_kind: :github
                    }}
  end

  defp collect_requests(count, acc \\ [])
  defp collect_requests(0, acc), do: Enum.reverse(acc)

  defp collect_requests(count, acc) do
    assert_receive {:github_request, request}
    collect_requests(count - 1, [request | acc])
  end
end
