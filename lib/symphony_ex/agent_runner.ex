defmodule SymphonyEx.AgentRunner do
  @moduledoc """
  Manages a single issue execution: spawns Codex app-server,
  sends the prompt, processes turns, and collects results.
  """
  require Logger

  alias SymphonyEx.Codex.AppServer
  alias SymphonyEx.Domain.{Events, Issue}
  alias SymphonyEx.GitHub.Client
  alias SymphonyEx.{Logging, PromptBuilder, RunEventLogger, SessionStore, Telemetry}

  @fatal_tool_failure_patterns [
    "write_stdin failed: stdin is closed for this session",
    "stdin is closed for this session"
  ]

  @blocked_result_patterns [
    ~r/\bSTATUS:\s*BLOCKED\b/i,
    ~r/\bBLOCKED:\b/i,
    ~r/\bunable to complete\b/i,
    ~r/\bcannot complete\b/i,
    ~r/\bcould not complete\b/i,
    ~r/\brequires a gstack-aware environment\b/i,
    ~r/\bmissing shared libraries\b/i,
    ~r/libatk-1\.0\.so\.0/i
  ]

  @type run_result :: %{
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          session_id: String.t() | nil,
          recovery_count: non_neg_integer(),
          events: [Events.t()],
          status: :success | :failed | :cancelled,
          error: String.t() | nil,
          error_category: String.t() | nil,
          last_message: String.t() | nil,
          last_event: String.t() | nil,
          elapsed_ms: non_neg_integer() | nil
        }

  @spec run(Issue.t(), keyword()) :: run_result()
  def run(issue, opts) do
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    workflow_path = Keyword.fetch!(opts, :workflow_path)
    codex_config = Keyword.fetch!(opts, :codex)
    comments = Keyword.get(opts, :comments, [])
    context_docs = Keyword.get(opts, :context_docs, "")
    app_server = Keyword.get(opts, :app_server, AppServer)

    command = build_codex_command(codex_config)
    turn_timeout = Keyword.get(codex_config, :turn_timeout_ms, 3_600_000)
    stall_timeout = Keyword.get(codex_config, :stall_timeout_ms, 300_000)

    recovered_session = load_recoverable_session(workspace_path)

    Logging.with_metadata(
      [
        Logging.issue_metadata(issue),
        Logging.session_metadata(recovered_session),
        %{workspace_path: workspace_path}
      ],
      fn ->
        Logger.info("starting agent run")

        :ok =
          RunEventLogger.log_run_started(workspace_path, issue, %{
            phase: "starting",
            recovered: not is_nil(recovered_session),
            recovery_count: recovery_count(recovered_session),
            session_id: recovered_session && recovered_session.session_id,
            thread_id: recovered_thread_id(recovered_session),
            workspace_path: workspace_path
          })

        case PromptBuilder.build(workflow_path, issue,
               comments: comments,
               context_docs: context_docs,
               workflow_store: Keyword.get(opts, :workflow_store, SymphonyEx.WorkflowStore),
               workspace_path: workspace_path
             ) do
          {:ok, prompt} ->
            {:ok, server} = app_server.start_link(command: command, cwd: workspace_path)
            app_server.subscribe(server)

            try do
              run_session(
                app_server,
                server,
                prompt,
                issue,
                workspace_path,
                codex_config,
                turn_timeout,
                stall_timeout,
                recovered_session
              )
            after
              app_server.shutdown(server)
            end

          {:error, reason} ->
            build_prestart_failure(issue, workspace_path, recovered_session, reason)
        end
      end
    )
  end

  @spec run_session(
          module(),
          GenServer.server(),
          String.t(),
          Issue.t(),
          Path.t(),
          keyword(),
          pos_integer(),
          pos_integer(),
          SessionStore.session_data() | nil
        ) ::
          run_result()
  defp run_session(
         app_server,
         server,
         prompt,
         issue,
         workspace_path,
         codex_config,
         turn_timeout,
         stall_timeout,
         recovered_session
       ) do
    with {:ok, _init_result} <- app_server.initialize(server),
         capabilities = app_server.capabilities(server),
         {:ok, thread_result} <-
           app_server.start_thread(
             server,
             thread_start_params(recovered_session, workspace_path, codex_config)
           ),
         thread_id <-
           thread_result["threadId"] || thread_result["thread_id"] ||
             get_in(thread_result, ["thread", "id"]),
         {:ok, session} <-
           persist_session_started(
             workspace_path,
             issue,
             capabilities,
             recovered_session,
             thread_id
           ),
         {:ok, _turn_result} <-
           app_server.start_turn(
             server,
             turn_start_params(thread_id, prompt, workspace_path, codex_config)
           ) do
      Logger.metadata(
        Logging.logger_metadata(
          Logging.run_metadata(issue,
            thread_id: thread_id,
            session_id: session.session_id,
            recovered: not is_nil(recovered_session),
            recovery_count: session.recovery_count,
            workspace_path: workspace_path,
            last_event: session.last_event
          )
        )
      )

      Logger.info("agent session initialized")

      wait_for_completion(
        app_server,
        server,
        issue,
        workspace_path,
        thread_id,
        session,
        turn_timeout,
        stall_timeout
      )
    else
      {:error, error} ->
        Logger.error("agent session failed",
          error: inspect(error),
          error_category: "startup_failed"
        )

        result = %{
          thread_id: recovered_thread_id(recovered_session),
          turn_id: nil,
          session_id: recovered_session && recovered_session.session_id,
          recovery_count: recovery_count(recovered_session),
          events: safe_get_events(app_server, server),
          status: :failed,
          error: inspect(error),
          error_category: "startup_failed",
          last_message: nil,
          last_event: nil,
          elapsed_ms: nil
        }

        persist_failed_session(
          workspace_path,
          issue,
          app_server.capabilities(server),
          recovered_session,
          result.thread_id,
          result.error,
          result.error_category,
          nil
        )

        :ok =
          RunEventLogger.log_run_finished(workspace_path, issue, %{
            thread_id: result.thread_id,
            status: Atom.to_string(result.status),
            error: result.error,
            error_category: result.error_category,
            phase: "startup_failed"
          })

        result
    end
  end

  @type wait_ctx :: %{
          app_server: module(),
          server: GenServer.server(),
          issue: Issue.t(),
          workspace_path: Path.t(),
          thread_id: String.t() | nil,
          session: SessionStore.session_data(),
          deadline: integer(),
          stall_timeout: pos_integer()
        }

  @spec wait_for_completion(
          module(),
          GenServer.server(),
          Issue.t(),
          Path.t(),
          String.t() | nil,
          SessionStore.session_data(),
          pos_integer(),
          pos_integer()
        ) :: run_result()
  defp wait_for_completion(
         app_server,
         server,
         issue,
         workspace_path,
         thread_id,
         session,
         turn_timeout,
         stall_timeout
       ) do
    ctx = %{
      app_server: app_server,
      server: server,
      issue: issue,
      workspace_path: workspace_path,
      thread_id: thread_id,
      session: session,
      deadline: System.monotonic_time(:millisecond) + turn_timeout,
      stall_timeout: stall_timeout
    }

    do_wait(ctx, System.monotonic_time(:millisecond))
  end

  @spec do_wait(wait_ctx(), integer()) :: run_result()
  defp do_wait(ctx, last_activity) do
    now = System.monotonic_time(:millisecond)

    cond do
      now >= ctx.deadline ->
        Logger.warning(
          "turn timeout reached",
          Logging.logger_metadata(
            Logging.issue_metadata(ctx.issue)
            |> Map.merge(%{
              workspace_path: ctx.workspace_path,
              thread_id: ctx.thread_id,
              turn_id: ctx.session.turn_id,
              session_id: ctx.session.session_id,
              recovery_count: ctx.session.recovery_count,
              last_event: ctx.session.last_event
            })
          )
        )

        ctx.app_server.cancel_turn(ctx.server)
        build_result(ctx, :failed, "Turn timeout exceeded", "turn_timeout")

      now - last_activity >= ctx.stall_timeout ->
        Logger.warning(
          "stall timeout reached",
          Logging.logger_metadata(
            Logging.issue_metadata(ctx.issue)
            |> Map.merge(%{
              workspace_path: ctx.workspace_path,
              thread_id: ctx.thread_id,
              turn_id: ctx.session.turn_id,
              session_id: ctx.session.session_id,
              timeout_ms: ctx.stall_timeout,
              recovery_count: ctx.session.recovery_count,
              last_event: ctx.session.last_event
            })
          )
        )

        ctx.app_server.cancel_turn(ctx.server)
        build_result(ctx, :failed, "Stall timeout — no activity", "stalled")

      true ->
        remaining = min(ctx.deadline - now, ctx.stall_timeout - (now - last_activity))
        wait_ms = min(remaining, 2_000)

        receive do
          {:app_server_event, %Events{} = event} ->
            :ok =
              RunEventLogger.log_app_event(ctx.workspace_path, ctx.issue, ctx.thread_id, event)

            case event.event do
              :turn_completed ->
                elapsed = System.monotonic_time(:millisecond) - (ctx.deadline - ctx.stall_timeout)
                result = build_result(ctx, :success, nil, nil)
                Telemetry.emit_turn_completed(ctx.issue.identifier, elapsed, result.status)
                result

              :turn_failed ->
                Telemetry.emit_turn_completed(ctx.issue.identifier, nil, :failed)
                build_result(ctx, :failed, event.message, "turn_failed")

              :turn_cancelled ->
                Telemetry.emit_turn_completed(ctx.issue.identifier, nil, :cancelled)
                build_result(ctx, :cancelled, event.message, "turn_cancelled")

              _ ->
                # Update last activity timestamp for non-terminal events
                do_wait(ctx, now)
            end
        after
          wait_ms ->
            if ctx.app_server.alive?(ctx.server) do
              do_wait(ctx, last_activity)
            else
              build_result(ctx, :failed, "Codex process exited", "process_exit")
            end
        end
    end
  end

  @spec build_result(wait_ctx(), atom(), String.t() | nil, String.t() | nil) :: run_result()
  defp build_result(ctx, status, error, error_category) do
    session = ctx.session
    started_at_ms = iso8601_to_system_ms(session.updated_at)
    finished_at_ms = System.system_time(:millisecond)
    elapsed_ms = max(finished_at_ms - started_at_ms, 0)
    events = safe_get_events(ctx.app_server, ctx.server)
    last_message = extract_last_message(events)
    last_event = extract_last_event_name(events)
    turn_id = extract_last_turn_id(events) || session.turn_id

    result =
      %{
        thread_id: ctx.thread_id,
        turn_id: turn_id,
        session_id: session.session_id,
        recovery_count: session.recovery_count,
        events: events,
        status: status,
        error: error,
        error_category: error_category,
        last_message: last_message,
        last_event: last_event,
        elapsed_ms: elapsed_ms
      }
      |> validate_success_result(events, ctx.issue)

    persist_terminal_session(
      ctx.workspace_path,
      ctx.issue,
      ctx.app_server.capabilities(ctx.server),
      session,
      result
    )

    outcome_kind = Logging.outcome_kind(result.status, result.error)

    Logger.info(
      "agent run finished",
      Logging.logger_metadata(
        Logging.run_metadata(ctx.issue,
          workspace_path: ctx.workspace_path,
          thread_id: ctx.thread_id,
          turn_id: turn_id,
          session_id: session.session_id,
          elapsed_ms: elapsed_ms,
          outcome_kind: outcome_kind,
          error_category: result.error_category,
          recovered: session.recovery_count > 0,
          recovery_count: session.recovery_count,
          last_event: last_event
        )
      )
    )

    :ok =
      RunEventLogger.log_run_finished(ctx.workspace_path, ctx.issue, %{
        thread_id: ctx.thread_id,
        turn_id: turn_id,
        session_id: session.session_id,
        status: Atom.to_string(result.status),
        outcome_kind: outcome_kind,
        elapsed_ms: elapsed_ms,
        recovered: session.recovery_count > 0,
        recovery_count: session.recovery_count,
        error: result.error,
        error_category: result.error_category,
        last_message: result.last_message,
        last_event: last_event,
        usage: extract_last_usage(events)
      })

    Telemetry.emit_run_finished(ctx.issue.identifier, result.status, elapsed_ms)

    result
  end

  @spec build_prestart_failure(Issue.t(), Path.t(), SessionStore.session_data() | nil, term()) ::
          run_result()
  defp build_prestart_failure(issue, workspace_path, recovered_session, reason) do
    {error, error_category} = classify_prestart_failure(reason)

    Logger.error(
      "agent prompt build failed",
      Logging.logger_metadata(
        Logging.issue_metadata(issue)
        |> Map.merge(%{
          workspace_path: workspace_path,
          error: error,
          error_category: error_category,
          recovered: not is_nil(recovered_session),
          recovery_count: recovery_count(recovered_session)
        })
      )
    )

    result = %{
      thread_id: recovered_thread_id(recovered_session),
      turn_id: nil,
      session_id: recovered_session && recovered_session.session_id,
      recovery_count: recovery_count(recovered_session),
      events: [],
      status: :failed,
      error: error,
      error_category: error_category,
      last_message: nil,
      last_event: nil,
      elapsed_ms: nil
    }

    persist_failed_session(
      workspace_path,
      issue,
      %{},
      recovered_session,
      result.thread_id,
      result.error,
      result.error_category,
      nil
    )

    :ok =
      RunEventLogger.log_run_finished(workspace_path, issue, %{
        thread_id: result.thread_id,
        status: Atom.to_string(result.status),
        error: result.error,
        error_category: result.error_category,
        phase: "startup_failed"
      })

    result
  end

  @spec classify_prestart_failure(term()) :: {String.t(), String.t()}
  defp classify_prestart_failure({:missing_skill_reference, name, paths}) do
    expected = Enum.map_join(paths, ", ", &to_string/1)

    {"Referenced skill $#{name} is not installed. Expected one of: #{expected}",
     "missing_skill_reference"}
  end

  defp classify_prestart_failure({:missing_external_reference, name}) do
    {"Referenced command $#{name} is not installed or not on PATH", "missing_external_reference"}
  end

  defp classify_prestart_failure(reason), do: {inspect(reason), "startup_failed"}

  @spec extract_last_message([Events.t()]) :: String.t() | nil
  defp extract_last_message(events) do
    events
    |> Enum.find_value(fn
      %Events{message: msg} when is_binary(msg) and msg != "" -> msg
      _ -> nil
    end)
  end

  @spec extract_last_event_name([Events.t()]) :: String.t() | nil
  defp extract_last_event_name([]), do: nil
  defp extract_last_event_name([event | _]), do: Atom.to_string(event.event)

  @spec extract_last_usage([Events.t()]) :: Events.usage() | nil
  defp extract_last_usage(events) do
    Enum.find_value(events, fn
      %Events{usage: %{} = usage} -> usage
      _ -> nil
    end)
  end

  @spec extract_last_turn_id([Events.t()]) :: String.t() | nil
  defp extract_last_turn_id(events) do
    Enum.find_value(events, fn
      %Events{params: %{} = params} -> params["turnId"] || params["turn_id"]
      _ -> nil
    end)
  end

  @spec validate_success_result(run_result(), [Events.t()], Issue.t()) :: run_result()
  defp validate_success_result(%{status: :success} = result, events, issue) do
    case blocked_result_message(result, events) do
      {:blocked, message} ->
        %{
          result
          | status: :failed,
            error: message,
            error_category: "blocked",
            last_message: result.last_message || message
        }

      nil ->
        with :ok <- verify_required_outputs(issue),
             thread_log_path when is_binary(thread_log_path) <- extract_thread_log_path(events),
             turn_id when is_binary(turn_id) <- result.turn_id,
             {:error, message, category} <- detect_fatal_tool_failure(thread_log_path, turn_id) do
          %{
            result
            | status: :failed,
              error: message,
              error_category: category,
              last_message: result.last_message || message
          }
        else
          {:error, message, category} ->
            %{
              result
              | status: :failed,
                error: message,
                error_category: category,
                last_message: result.last_message || message
            }

          _ ->
            result
        end
    end
  end

  defp validate_success_result(result, _events, _issue), do: result

  @spec extract_thread_log_path([Events.t()]) :: String.t() | nil
  defp extract_thread_log_path(events) do
    Enum.find_value(events, fn
      %Events{params: %{"thread" => %{"path" => path}}} when is_binary(path) -> path
      %Events{params: %{"threadPath" => path}} when is_binary(path) -> path
      _ -> nil
    end)
  end

  @spec detect_fatal_tool_failure(Path.t(), String.t()) :: :ok | {:error, String.t(), String.t()}
  defp detect_fatal_tool_failure(log_path, turn_id) do
    if File.regular?(log_path) do
      log_path
      |> File.stream!([], :line)
      |> Enum.reduce_while({false, :ok}, fn line, {capturing?, _status} ->
        case Jason.decode(line) do
          {:ok,
           %{
             "type" => "event_msg",
             "payload" => %{"type" => "task_started", "turn_id" => ^turn_id}
           }} ->
            {:cont, {true, :ok}}

          {:ok,
           %{
             "type" => "event_msg",
             "payload" => %{"type" => "task_complete", "turn_id" => ^turn_id}
           }} ->
            {:halt, {false, :ok}}

          {:ok, entry} when capturing? ->
            case fatal_tool_failure_entry(entry) do
              nil -> {:cont, {true, :ok}}
              {message, category} -> {:halt, {true, {:error, message, category}}}
            end

          _ ->
            {:cont, {capturing?, :ok}}
        end
      end)
      |> elem(1)
    else
      :ok
    end
  end

  @spec fatal_tool_failure_entry(map()) :: {String.t(), String.t()} | nil
  defp fatal_tool_failure_entry(%{
         "type" => "response_item",
         "payload" => %{"type" => "function_call_output", "output" => output}
       })
       when is_binary(output) do
    fatal_tool_failure(output)
  end

  defp fatal_tool_failure_entry(%{
         "type" => "event_msg",
         "payload" => %{"type" => "exec_command_end", "aggregated_output" => output}
       })
       when is_binary(output) do
    fatal_tool_failure(output)
  end

  defp fatal_tool_failure_entry(_entry), do: nil

  @spec fatal_tool_failure(String.t()) :: {String.t(), String.t()} | nil
  defp fatal_tool_failure(output) do
    if Enum.any?(@fatal_tool_failure_patterns, &String.contains?(output, &1)) do
      {String.trim(output), "tool_execution_failed"}
    end
  end

  @spec verify_required_outputs(Issue.t()) :: :ok | {:error, String.t(), String.t()}
  defp verify_required_outputs(%Issue{} = issue) do
    if issue_requires_body_update?(issue) do
      case issue_body_updated_or_pr_created?(issue) do
        {:ok, true} ->
          :ok

        {:ok, false} ->
          {:error,
           "Issue required a body update, but neither the GitHub issue body nor a linked PR reflected the final state",
           "required_output_missing"}

        {:error, reason} ->
          {:error, "Issue required a body update, but verification failed: #{inspect(reason)}",
           "required_output_unverified"}
      end
    else
      :ok
    end
  end

  @spec issue_requires_body_update?(Issue.t()) :: boolean()
  defp issue_requires_body_update?(%Issue{description: description})
       when is_binary(description) do
    String.match?(description, ~r/이슈\s*본문.*업데이트|issue\s+body|update\s+the\s+issue\s+body/i)
  end

  defp issue_requires_body_update?(_issue), do: false

  @spec issue_body_updated_or_pr_created?(Issue.t()) :: {:ok, boolean()} | {:error, term()}
  defp issue_body_updated_or_pr_created?(%Issue{} = issue) do
    fetcher =
      Application.get_env(
        :symphony_ex,
        :agent_runner_issue_body_fetcher,
        &default_fetch_issue_body/1
      )

    pr_fetcher =
      Application.get_env(
        :symphony_ex,
        :agent_runner_issue_pr_fetcher,
        &default_fetch_issue_prs/1
      )

    with {:ok, latest_body} <- fetcher.(issue),
         {:ok, prs} <- pr_fetcher.(issue) do
      body_updated =
        normalize_issue_body(latest_body) != normalize_issue_body(issue.description || "")

      {:ok, body_updated or pr_exists_for_issue(issue, prs)}
    end
  end

  @spec default_fetch_issue_body(Issue.t()) :: {:ok, String.t()} | {:error, term()}
  defp default_fetch_issue_body(%Issue{} = issue) do
    case Client.fetch_issue(issue.identifier, github_client_opts()) do
      {:ok, %{} = latest_issue} -> {:ok, latest_issue["body"] || ""}
      {:ok, nil} -> {:error, :issue_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec default_fetch_issue_prs(Issue.t()) :: {:ok, [map()]} | {:error, term()}
  defp default_fetch_issue_prs(%Issue{} = _issue) do
    Client.list_pull_requests(github_client_opts())
  end

  @spec pr_exists_for_issue(Issue.t(), [map()]) :: boolean()
  defp pr_exists_for_issue(%Issue{} = issue, prs) do
    Enum.any?(prs, &related_pr_matches_issue?(&1, issue))
  end

  @spec related_pr_matches_issue?(map(), Issue.t()) :: boolean()
  defp related_pr_matches_issue?(pr, %Issue{} = issue) do
    pr_number = pr["number"]
    body = pr["body"] || ""
    head_ref = get_in(pr, ["head", "ref"]) || pr["headRefName"] || ""
    issue_number = to_string(issue.identifier)

    explicit_target_match? =
      cond do
        is_integer(issue.target_pr) and is_binary(issue.target_branch) ->
          pr_number == issue.target_pr and head_ref == issue.target_branch

        is_integer(issue.target_pr) ->
          pr_number == issue.target_pr

        is_binary(issue.target_branch) and String.trim(issue.target_branch) != "" ->
          head_ref == issue.target_branch

        true ->
          nil
      end

    case explicit_target_match? do
      nil ->
        String.contains?(body, "##{issue_number}") or
          String.contains?(head_ref, "issue-#{issue_number}")

      value ->
        value
    end
  end

  @spec github_client_opts() :: keyword()
  defp github_client_opts do
    [
      api_key: System.get_env("GITHUB_TOKEN"),
      owner: System.get_env("GITHUB_OWNER"),
      repo: System.get_env("GITHUB_REPO")
    ]
  end

  @spec normalize_issue_body(String.t()) :: String.t()
  defp normalize_issue_body(body) do
    body
    |> String.replace(~r/<!-- symphony:managed -->.*?<!-- \/symphony:managed -->/s, "")
    |> String.trim()
  end

  @spec blocked_result_message(run_result(), [Events.t()]) :: {:blocked, String.t()} | nil
  defp blocked_result_message(result, events) do
    messages =
      [result.error, result.last_message]
      |> Kernel.++(Enum.flat_map(events, &event_messages/1))
      |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))

    Enum.find_value(messages, fn message ->
      if blocked_message?(message) do
        {:blocked, blocked_message_summary(message)}
      end
    end)
  end

  @spec event_messages(Events.t()) :: [String.t()]
  defp event_messages(%Events{message: message, params: params}) do
    [message | nested_event_messages(params)]
  end

  @spec nested_event_messages(term()) :: [String.t()]
  defp nested_event_messages(value) when is_binary(value), do: [value]

  defp nested_event_messages(value) when is_list(value) do
    Enum.flat_map(value, &nested_event_messages/1)
  end

  defp nested_event_messages(value) when is_map(value) do
    value
    |> Map.values()
    |> Enum.flat_map(&nested_event_messages/1)
  end

  defp nested_event_messages(_value), do: []

  @spec blocked_message?(String.t()) :: boolean()
  defp blocked_message?(message) do
    Enum.any?(@blocked_result_patterns, &Regex.match?(&1, message))
  end

  @spec blocked_message_summary(String.t()) :: String.t()
  defp blocked_message_summary(message) do
    cond do
      Regex.match?(~r/libatk-1\.0\.so\.0/i, message) ->
        "Agent reported a blocked outcome because the required browser runtime dependency libatk-1.0.so.0 is missing"

      Regex.match?(~r/\bSTATUS:\s*BLOCKED\b/i, message) ->
        "Agent reported a blocked outcome"

      true ->
        "Agent reported a blocked outcome: #{String.slice(message, 0, 240)}"
    end
  end

  @spec load_recoverable_session(Path.t()) :: SessionStore.session_data() | nil
  defp load_recoverable_session(workspace_path) do
    with {:ok, session} when not is_nil(session) <- SessionStore.load(workspace_path),
         true <- SessionStore.recoverable?(session),
         {:ok, updated} <- SessionStore.mark_recovered(workspace_path) do
      Logger.info(
        "recoverable session found",
        Logging.logger_metadata(
          Logging.session_metadata(updated)
          |> Map.put(:workspace_path, workspace_path)
        )
      )

      updated
    else
      _ -> nil
    end
  end

  @spec thread_start_params(SessionStore.session_data() | nil, String.t(), keyword()) :: map()
  defp thread_start_params(session, workspace_path, codex_config) do
    %{}
    |> maybe_put_thread_id(session)
    |> Map.put("cwd", workspace_path)
    |> maybe_put(
      "approvalPolicy",
      app_server_approval_policy(Keyword.get(codex_config, :approval_policy))
    )
    |> maybe_put("sandbox", app_server_thread_sandbox(Keyword.get(codex_config, :thread_sandbox)))
  end

  @spec turn_start_params(String.t(), String.t(), String.t(), keyword()) :: map()
  defp turn_start_params(thread_id, prompt, workspace_path, codex_config) do
    %{
      "input" => [%{"type" => "text", "text" => prompt}],
      "threadId" => thread_id,
      "cwd" => workspace_path
    }
    |> maybe_put(
      "sandboxPolicy",
      app_server_turn_sandbox(Keyword.get(codex_config, :thread_sandbox), workspace_path)
    )
  end

  @spec build_codex_command(keyword()) :: String.t()
  defp build_codex_command(codex_config) do
    codex_config
    |> Keyword.get(:command, "codex app-server")
    |> maybe_append_config_override(
      "approval_policy",
      codex_cli_approval_policy(Keyword.get(codex_config, :approval_policy))
    )
    |> maybe_append_config_override(
      "sandbox_mode",
      codex_cli_sandbox_mode(Keyword.get(codex_config, :thread_sandbox))
    )
  end

  @spec maybe_append_config_override(String.t(), String.t(), String.t() | nil) :: String.t()
  defp maybe_append_config_override(command, _key, nil), do: command

  defp maybe_append_config_override(command, key, value) do
    if String.contains?(command, key) do
      command
    else
      command <> ~s( -c ) <> key <> ~s(=\") <> value <> ~s(\")
    end
  end

  @spec maybe_put_thread_id(map(), SessionStore.session_data() | nil) :: map()
  defp maybe_put_thread_id(params, nil), do: params
  defp maybe_put_thread_id(params, %{thread_id: nil}), do: params

  defp maybe_put_thread_id(params, %{thread_id: thread_id}),
    do: Map.put(params, "threadId", thread_id)

  @spec maybe_put(map(), String.t(), any()) :: map()
  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  @spec codex_cli_approval_policy(atom() | nil) :: String.t() | nil
  defp codex_cli_approval_policy(nil), do: nil
  defp codex_cli_approval_policy(:never), do: "never"
  defp codex_cli_approval_policy(:on_request), do: "on-request"
  defp codex_cli_approval_policy(:on_failure), do: "on-request"
  defp codex_cli_approval_policy(value) when is_binary(value), do: value

  @spec app_server_approval_policy(atom() | nil) :: String.t() | nil
  defp app_server_approval_policy(nil), do: nil
  defp app_server_approval_policy(:never), do: "never"
  defp app_server_approval_policy(:on_request), do: "onRequest"
  defp app_server_approval_policy(:on_failure), do: "onRequest"
  defp app_server_approval_policy(value) when is_binary(value), do: value

  @spec codex_cli_sandbox_mode(String.t() | nil) :: String.t() | nil
  defp codex_cli_sandbox_mode(nil), do: nil
  defp codex_cli_sandbox_mode("workspaceWrite"), do: "workspace-write"
  defp codex_cli_sandbox_mode("workspace-write"), do: "workspace-write"
  defp codex_cli_sandbox_mode("readOnly"), do: "read-only"
  defp codex_cli_sandbox_mode("read-only"), do: "read-only"
  defp codex_cli_sandbox_mode("dangerFullAccess"), do: "danger-full-access"
  defp codex_cli_sandbox_mode("danger-full-access"), do: "danger-full-access"
  defp codex_cli_sandbox_mode("externalSandbox"), do: "danger-full-access"
  defp codex_cli_sandbox_mode("external-sandbox"), do: "danger-full-access"

  @spec app_server_thread_sandbox(String.t() | nil) :: String.t() | nil
  defp app_server_thread_sandbox(nil), do: nil
  defp app_server_thread_sandbox("workspaceWrite"), do: "workspace-write"
  defp app_server_thread_sandbox("workspace-write"), do: "workspace-write"
  defp app_server_thread_sandbox("readOnly"), do: "read-only"
  defp app_server_thread_sandbox("read-only"), do: "read-only"
  defp app_server_thread_sandbox("dangerFullAccess"), do: "danger-full-access"
  defp app_server_thread_sandbox("danger-full-access"), do: "danger-full-access"
  defp app_server_thread_sandbox("externalSandbox"), do: "danger-full-access"
  defp app_server_thread_sandbox("external-sandbox"), do: "danger-full-access"

  @spec app_server_turn_sandbox(String.t() | nil, String.t()) :: map() | nil
  defp app_server_turn_sandbox(nil, _workspace_path), do: nil

  defp app_server_turn_sandbox("workspaceWrite", workspace_path) do
    %{"type" => "workspaceWrite", "writableRoots" => [workspace_path], "networkAccess" => true}
  end

  defp app_server_turn_sandbox("workspace-write", workspace_path),
    do: app_server_turn_sandbox("workspaceWrite", workspace_path)

  defp app_server_turn_sandbox("readOnly", _workspace_path) do
    %{"type" => "readOnly", "access" => %{"type" => "fullAccess"}}
  end

  defp app_server_turn_sandbox("read-only", workspace_path),
    do: app_server_turn_sandbox("readOnly", workspace_path)

  defp app_server_turn_sandbox("dangerFullAccess", _workspace_path) do
    %{"type" => "dangerFullAccess"}
  end

  defp app_server_turn_sandbox("danger-full-access", workspace_path),
    do: app_server_turn_sandbox("dangerFullAccess", workspace_path)

  defp app_server_turn_sandbox("externalSandbox", _workspace_path) do
    %{"type" => "externalSandbox", "networkAccess" => "enabled"}
  end

  defp app_server_turn_sandbox("external-sandbox", workspace_path),
    do: app_server_turn_sandbox("externalSandbox", workspace_path)

  @spec persist_session_started(
          Path.t(),
          Issue.t(),
          map(),
          SessionStore.session_data() | nil,
          String.t() | nil
        ) :: {:ok, SessionStore.session_data()} | {:error, term()}
  defp persist_session_started(workspace_path, issue, capabilities, recovered_session, thread_id) do
    SessionStore.save(workspace_path, %{
      session_id: recovered_session && recovered_session.session_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      thread_id: thread_id,
      turn_id: recovered_session && recovered_session.turn_id,
      turns_executed: turns_executed(recovered_session),
      capability_profile: capabilities,
      recovery_count: recovery_count(recovered_session),
      last_event: "thread_started",
      phase: :running,
      error: nil,
      error_category: nil
    })
  end

  @spec persist_terminal_session(
          Path.t(),
          Issue.t(),
          map(),
          SessionStore.session_data(),
          run_result()
        ) :: :ok
  defp persist_terminal_session(workspace_path, issue, capabilities, session, result) do
    attrs = %{
      session_id: session.session_id,
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      thread_id: result.thread_id,
      turn_id: result.turn_id,
      turns_executed: session.turns_executed + 1,
      capability_profile: capabilities,
      recovery_count: session.recovery_count,
      last_event: result.last_event,
      phase: terminal_phase(result.status),
      error: result.error,
      error_category: result.error_category
    }

    case result.status do
      :success ->
        _ = SessionStore.delete(workspace_path)
        :ok

      _other ->
        _ = SessionStore.save(workspace_path, attrs)
        :ok
    end
  end

  @spec persist_failed_session(
          Path.t(),
          Issue.t(),
          map(),
          SessionStore.session_data() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil,
          String.t() | nil
        ) :: :ok
  defp persist_failed_session(
         workspace_path,
         issue,
         capabilities,
         recovered_session,
         thread_id,
         error,
         error_category,
         turn_id
       ) do
    _ =
      SessionStore.save(workspace_path, %{
        session_id: recovered_session && recovered_session.session_id,
        issue_id: issue.id,
        issue_identifier: issue.identifier,
        thread_id: thread_id,
        turn_id: turn_id || (recovered_session && recovered_session.turn_id),
        turns_executed: turns_executed(recovered_session),
        capability_profile: capabilities,
        recovery_count: recovery_count(recovered_session),
        last_event: "startup_failed",
        phase: :failed,
        error: error,
        error_category: error_category
      })

    :ok
  end

  @spec turns_executed(SessionStore.session_data() | nil) :: non_neg_integer()
  defp turns_executed(nil), do: 0
  defp turns_executed(session), do: session.turns_executed

  @spec recovery_count(SessionStore.session_data() | nil) :: non_neg_integer()
  defp recovery_count(nil), do: 0
  defp recovery_count(session), do: session.recovery_count

  @spec recovered_thread_id(SessionStore.session_data() | nil) :: String.t() | nil
  defp recovered_thread_id(nil), do: nil
  defp recovered_thread_id(session), do: session.thread_id

  @spec terminal_phase(:success | :failed | :cancelled) :: SessionStore.phase()
  defp terminal_phase(:success), do: :completed
  defp terminal_phase(:failed), do: :failed
  defp terminal_phase(:cancelled), do: :failed

  @spec iso8601_to_system_ms(String.t() | nil) :: integer()
  defp iso8601_to_system_ms(nil), do: System.system_time(:millisecond)

  defp iso8601_to_system_ms(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  @spec safe_get_events(module(), GenServer.server()) :: [Events.t()]
  defp safe_get_events(app_server, server) do
    app_server.get_events(server)
  catch
    :exit, _ -> []
  end
end
