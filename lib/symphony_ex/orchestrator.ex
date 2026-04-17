defmodule SymphonyEx.Orchestrator do
  @moduledoc """
  Polls tracker candidates, persists bounded run-state updates, and dispatches
  issue execution tasks through a supervised worker pool.

  Candidate selection is intentionally split into:

    * priority/order — which eligible issue should run first
    * eligibility/gating — whether an issue may run right now
    * concurrency class limits — bounded parallelism per issue class
    * conflict boundaries — scopes that must serialize across parallel dispatch

  That keeps the single-issue prototype compatible with future parallel dispatch.
  """

  use GenServer
  require Logger

  alias SymphonyEx.{
    AgentRunner,
    Dashboard,
    GitHub.Adapter,
    Logging,
    Observability,
    RuntimeSnapshot,
    Telemetry,
    WorkflowStore,
    Workspace
  }

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.Orchestrator.Lifecycle

  @type run_state :: :claimed | :running | :retry_queued | :released
  @type concurrency_class :: atom()
  @type conflict_key :: String.t()

  @type running_entry :: %{
          issue: Issue.t(),
          task: Task.t(),
          workspace_path: String.t(),
          state: run_state(),
          attempt: non_neg_integer(),
          concurrency_class: concurrency_class(),
          conflict_keys: MapSet.t(conflict_key()),
          started_at: DateTime.t(),
          started_at_ms: integer(),
          started_at_mono_ms: integer()
        }

  @type retry_entry :: %{
          issue: Issue.t(),
          attempt: pos_integer(),
          due_at_ms: integer(),
          queued_at: DateTime.t(),
          queued_at_ms: integer(),
          queued_at_mono_ms: integer(),
          backoff_ms: pos_integer(),
          last_result: term(),
          concurrency_class: concurrency_class(),
          conflict_keys: MapSet.t(conflict_key())
        }

  @type state :: %{
          tracker: module(),
          tracker_opts: keyword(),
          lifecycle: Lifecycle.t(),
          explicit_issue_identifier: String.t() | nil,
          completed_issue_identifiers: MapSet.t(String.t()),
          completed: [map()],
          workspace: module(),
          workspace_opts: keyword(),
          agent_runner: module(),
          workflow_path: String.t() | nil,
          codex_opts: keyword(),
          poll_interval_ms: pos_integer(),
          max_concurrent: pos_integer(),
          max_retries: non_neg_integer(),
          retry_backoff_ms: pos_integer(),
          max_retry_backoff_ms: pos_integer(),
          task_supervisor: GenServer.name(),
          blocked_labels: MapSet.t(String.t()),
          concurrency_limits: %{concurrency_class() => pos_integer()},
          serialization_label_prefixes: [String.t()],
          default_conflict_scope_to_class: boolean(),
          running: %{String.t() => running_entry()},
          retry_queue: %{String.t() => retry_entry()},
          retries: %{String.t() => non_neg_integer()},
          last_persisted_payloads: %{String.t() => map()},
          deferral_counts: %{String.t() => non_neg_integer()},
          last_runtime_snapshot_fingerprint: integer() | nil,
          candidate_poll_interval_ms: pos_integer(),
          next_candidate_poll_at_ms: integer(),
          next_candidate_poll_at_system_ms: integer()
        }

  @default_blocked_labels ["blocked", "human-blocked", "needs-human", "do-not-dispatch"]
  @default_concurrency_limits %{code: 1, docs: 2, infra: 1, default: 1}
  @default_serialization_label_prefixes ["scope:", "service:", "path:", "package:", "release:"]
  @default_starvation_bonus_step 25
  @default_starvation_bonus_cap 100
  @github_visible_gating_reasons [
    :dependency_blocked,
    :human_blocked,
    :missing_required_metadata,
    :missing_title,
    :serialized_conflict
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec snapshot(GenServer.server()) :: state()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    base_tracker_opts = Keyword.get(opts, :tracker_opts, [])

    lifecycle =
      case Keyword.get(opts, :lifecycle) || Keyword.get(base_tracker_opts, :lifecycle) do
        %Lifecycle{} = lc -> lc
        lifecycle_opts when is_list(lifecycle_opts) -> Lifecycle.new(lifecycle_opts)
        nil -> Lifecycle.default()
      end

    tracker_opts =
      if Keyword.has_key?(base_tracker_opts, :lifecycle),
        do: base_tracker_opts,
        else: Keyword.put(base_tracker_opts, :lifecycle, lifecycle)

    now_mono_ms = System.monotonic_time(:millisecond)
    now_system_ms = System.system_time(:millisecond)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, 30_000)

    state = %{
      tracker: Keyword.get(opts, :tracker, Adapter),
      explicit_issue_identifier: explicit_issue_identifier(opts, base_tracker_opts),
      completed_issue_identifiers: MapSet.new(),
      completed: [],
      tracker_opts: tracker_opts,
      lifecycle: lifecycle,
      workspace: Keyword.get(opts, :workspace, Workspace),
      workspace_opts: Keyword.get(opts, :workspace_opts, []),
      agent_runner: Keyword.get(opts, :agent_runner, AgentRunner),
      workflow_path: Keyword.get(opts, :workflow_path),
      codex_opts: Keyword.get(opts, :codex, []),
      poll_interval_ms: poll_interval_ms,
      max_concurrent: Keyword.get(opts, :max_concurrent, 1),
      max_retries: Keyword.get(opts, :max_retries, 2),
      retry_backoff_ms: Keyword.get(opts, :retry_backoff_ms, 5_000),
      max_retry_backoff_ms: Keyword.get(opts, :max_retry_backoff_ms, 60_000),
      task_supervisor: Keyword.get(opts, :task_supervisor, SymphonyEx.AgentWorkers),
      blocked_labels: blocked_labels(opts),
      concurrency_limits: concurrency_limits(opts),
      serialization_label_prefixes: serialization_label_prefixes(opts),
      default_conflict_scope_to_class: Keyword.get(opts, :default_conflict_scope_to_class, true),
      running: %{},
      retry_queue: %{},
      retries: %{},
      last_persisted_payloads: %{},
      deferral_counts: %{},
      last_runtime_snapshot_fingerprint: nil,
      candidate_poll_interval_ms: poll_interval_ms,
      next_candidate_poll_at_ms: now_mono_ms,
      next_candidate_poll_at_system_ms: now_system_ms
    }

    send(self(), :tick)
    {:ok, publish_snapshot(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_info(:tick, state) do
    state = refresh_runtime_config(state)

    state =
      state
      |> cleanup_inactive_worktrees()
      |> dispatch_due_retries()
      |> maybe_dispatch_explicit_issue()
      |> maybe_dispatch_candidates()
      |> refresh_candidate_poll_backoff()

    state = publish_snapshot(state)
    Process.send_after(self(), :tick, state.poll_interval_ms)
    {:noreply, state}
  end

  def handle_info({ref, {:issue_finished, identifier, result}}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish_issue(identifier, result) |> publish_snapshot()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.running, fn {_id, %{task: task}} -> task.ref == ref end) do
      {identifier, _entry} ->
        {:noreply, state |> finish_issue(identifier, {:error, reason}) |> publish_snapshot()}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec refresh_runtime_config(state()) :: state()
  defp refresh_runtime_config(state) do
    if Process.whereis(WorkflowStore) do
      config = WorkflowStore.get_config()

      tracker_opts =
        config |> Keyword.get(:tracker, []) |> ensure_tracker_lifecycle(state.lifecycle)

      orchestrator_opts = Keyword.get(config, :orchestrator, [])

      state
      |> Map.put(:tracker_opts, tracker_opts)
      |> Map.put(
        :poll_interval_ms,
        Keyword.get(orchestrator_opts, :poll_interval_ms, state.poll_interval_ms)
      )
      |> Map.put(
        :max_concurrent,
        Keyword.get(orchestrator_opts, :max_concurrent, state.max_concurrent)
      )
      |> Map.put(:max_retries, Keyword.get(orchestrator_opts, :max_retries, state.max_retries))
      |> Map.put(
        :retry_backoff_ms,
        Keyword.get(orchestrator_opts, :backoff_base_ms, state.retry_backoff_ms)
      )
      |> Map.put(:blocked_labels, blocked_labels(orchestrator_opts))
      |> Map.put(:concurrency_limits, concurrency_limits(orchestrator_opts))
      |> Map.put(:serialization_label_prefixes, serialization_label_prefixes(orchestrator_opts))
      |> Map.put(
        :default_conflict_scope_to_class,
        Keyword.get(
          orchestrator_opts,
          :default_conflict_scope_to_class,
          state.default_conflict_scope_to_class
        )
      )
      |> Map.put(
        :explicit_issue_identifier,
        explicit_issue_identifier(orchestrator_opts, tracker_opts)
      )
    else
      state
    end
  end

  defp ensure_tracker_lifecycle(tracker_opts, fallback_lifecycle) do
    case Keyword.get(tracker_opts, :lifecycle) do
      %Lifecycle{} = lifecycle -> Keyword.put(tracker_opts, :lifecycle, lifecycle)
      _other -> Keyword.put_new(tracker_opts, :lifecycle, fallback_lifecycle)
    end
  end

  @spec dispatch_due_retries(state()) :: state()
  defp dispatch_due_retries(state) do
    if available_slots(state) == 0 do
      state
    else
      now = System.monotonic_time(:millisecond)

      state.retry_queue
      |> Enum.filter(fn {_identifier, retry} -> retry.due_at_ms <= now end)
      |> Enum.sort_by(fn {_identifier, retry} ->
        retry_sort_key(retry.issue, retry.due_at_ms, state)
      end)
      |> Enum.reduce_while(state, fn {identifier, retry}, acc ->
        acc = update_in(acc, [:retry_queue], &Map.delete(&1, identifier))
        reduce_retry_dispatch(acc, identifier, retry)
      end)
    end
  end

  @spec reduce_retry_dispatch(state(), String.t(), retry_entry()) ::
          {:cont, state()} | {:halt, state()}
  defp reduce_retry_dispatch(acc, identifier, retry) do
    case dispatch_candidate(acc, retry.issue, retry.attempt, :retry_due) do
      {:ok, next_state} ->
        {:cont, next_state}

      {:skip, next_state, reason} ->
        next_state =
          note_gated_issue(next_state, retry.issue, reason, classify_issue(retry.issue))

        {:cont, put_in(next_state, [:retry_queue, identifier], retry)}

      {:halt, next_state} ->
        {:halt, put_in(next_state, [:retry_queue, identifier], retry)}
    end
  end

  @spec maybe_dispatch_explicit_issue(state()) :: state()
  defp maybe_dispatch_explicit_issue(state) do
    identifier = state.explicit_issue_identifier

    if explicit_issue_dispatchable?(state, identifier) do
      do_dispatch_explicit_issue(state, identifier)
    else
      state
    end
  end

  @spec explicit_issue_dispatchable?(state(), String.t() | nil) :: boolean()
  defp explicit_issue_dispatchable?(_state, nil), do: false

  defp explicit_issue_dispatchable?(state, identifier) do
    available_slots(state) > 0 and
      not Map.has_key?(state.running, identifier) and
      not Map.has_key?(state.retry_queue, identifier) and
      not MapSet.member?(state.completed_issue_identifiers, identifier)
  end

  @spec do_dispatch_explicit_issue(state(), String.t()) :: state()
  defp do_dispatch_explicit_issue(state, identifier) do
    case state.tracker.fetch_issue_by_identifier(identifier, state.tracker_opts) do
      {:ok, %Issue{} = issue} ->
        handle_dispatch_result(state, dispatch_candidate(state, issue, 0, :explicit), issue)

      {:ok, nil} ->
        Logger.warning(
          "explicit issue not found",
          issue_identifier: identifier,
          dispatch_source: :explicit
        )

        mark_issue_completed(state, identifier)

      {:error, reason} ->
        Logger.warning(
          "explicit issue fetch failed",
          issue_identifier: identifier,
          dispatch_source: :explicit,
          tracker_error: inspect(reason)
        )

        state
    end
  end

  @spec handle_dispatch_result(
          state(),
          {:ok, state()} | {:skip, state(), atom()} | {:halt, state()},
          Issue.t()
        ) :: state()
  defp handle_dispatch_result(_state, {:ok, next_state}, _issue), do: next_state

  defp handle_dispatch_result(_state, {:skip, next_state, reason}, issue) do
    note_gated_issue(next_state, issue, reason, classify_issue(issue))
  end

  defp handle_dispatch_result(_state, {:halt, next_state}, _issue), do: next_state

  @spec maybe_dispatch_candidates(state()) :: state()
  defp maybe_dispatch_candidates(state) do
    cond do
      available_slots(state) == 0 ->
        state

      not candidate_poll_due?(state) ->
        state

      true ->
        case state.tracker.fetch_candidate_issues(state.tracker_opts) do
          {:ok, issues} ->
            {prioritized, next_state} = prioritize_candidates(issues, state)

            prioritized
            |> Enum.reduce_while(next_state, &reduce_candidate_dispatch/2)
            |> schedule_next_candidate_poll()

          {:error, reason} ->
            Logger.warning("tracker poll failed", tracker_error: inspect(reason))
            schedule_next_candidate_poll(state)
        end
    end
  end

  defp candidate_poll_due?(state) do
    System.monotonic_time(:millisecond) >= Map.get(state, :next_candidate_poll_at_ms, 0)
  end

  defp refresh_candidate_poll_backoff(state) do
    desired_interval = candidate_poll_interval_ms(state)
    now_mono_ms = System.monotonic_time(:millisecond)
    now_system_ms = System.system_time(:millisecond)

    current_next_mono = Map.get(state, :next_candidate_poll_at_ms, now_mono_ms)
    current_next_system = Map.get(state, :next_candidate_poll_at_system_ms, now_system_ms)
    desired_next_mono = now_mono_ms + desired_interval
    desired_next_system = now_system_ms + desired_interval

    state
    |> Map.put(:candidate_poll_interval_ms, desired_interval)
    |> Map.put(:next_candidate_poll_at_ms, max(current_next_mono, desired_next_mono))
    |> Map.put(:next_candidate_poll_at_system_ms, max(current_next_system, desired_next_system))
  end

  defp schedule_next_candidate_poll(state) do
    interval = candidate_poll_interval_ms(state)
    now_mono_ms = System.monotonic_time(:millisecond)
    now_system_ms = System.system_time(:millisecond)

    state
    |> Map.put(:candidate_poll_interval_ms, interval)
    |> Map.put(:next_candidate_poll_at_ms, now_mono_ms + interval)
    |> Map.put(:next_candidate_poll_at_system_ms, now_system_ms + interval)
  end

  defp candidate_poll_interval_ms(state) do
    base_interval_ms = state.poll_interval_ms
    github_rate_limit = Observability.snapshot() |> Map.get(:rate_limits, %{}) |> Map.get(:github)

    cond do
      is_map(github_rate_limit) and is_integer(github_rate_limit[:retry_after]) and
          github_rate_limit[:retry_after] > 0 ->
        max(base_interval_ms, github_rate_limit[:retry_after] * 1_000)

      is_map(github_rate_limit) and is_integer(github_rate_limit[:remaining]) and
          github_rate_limit[:remaining] <= 25 ->
        max(base_interval_ms * 8, 120_000)

      is_map(github_rate_limit) and is_integer(github_rate_limit[:remaining]) and
          github_rate_limit[:remaining] <= 100 ->
        max(base_interval_ms * 4, 60_000)

      is_map(github_rate_limit) and is_integer(github_rate_limit[:remaining]) and
          github_rate_limit[:remaining] <= 250 ->
        max(base_interval_ms * 2, 30_000)

      true ->
        base_interval_ms
    end
  end

  @spec reduce_candidate_dispatch(Issue.t(), state()) :: {:cont, state()} | {:halt, state()}
  defp reduce_candidate_dispatch(issue, acc) do
    case hydrate_candidate_issue(acc, issue) do
      {:ok, hydrated_issue} ->
        case dispatch_candidate(acc, hydrated_issue, 0, :candidate) do
          {:ok, updated_state} ->
            {:cont, updated_state}

          {:skip, updated_state, reason} ->
            {:cont,
             note_gated_issue(
               updated_state,
               hydrated_issue,
               reason,
               classify_issue(hydrated_issue)
             )}

          {:halt, updated_state} ->
            {:halt, updated_state}
        end

      {:skip, reason} ->
        {:cont, note_gated_issue(acc, issue, reason, classify_issue(issue))}
    end
  end

  @spec hydrate_candidate_issue(state(), Issue.t()) :: {:ok, Issue.t()} | {:skip, atom()}
  defp hydrate_candidate_issue(%{tracker: tracker}, %Issue{} = issue)
       when tracker != SymphonyEx.GitHub.Adapter do
    {:ok, issue}
  end

  defp hydrate_candidate_issue(state, %Issue{} = issue) do
    case state.tracker.fetch_issue_by_identifier(issue.identifier, state.tracker_opts) do
      {:ok, %Issue{} = hydrated_issue} -> {:ok, hydrated_issue}
      {:ok, nil} -> {:skip, :issue_not_found}
      {:error, _reason} -> {:skip, :issue_fetch_failed}
    end
  end

  @spec dispatch_candidate(state(), Issue.t(), non_neg_integer(), atom()) ::
          {:ok, state()} | {:skip, state(), atom()} | {:halt, state()}
  defp dispatch_candidate(state, issue, attempt, source) do
    if available_slots(state) == 0 do
      {:halt, state}
    else
      case dispatch_eligibility(state, issue) do
        :ok ->
          Logger.debug(
            "dispatching issue",
            Logging.logger_metadata(
              Logging.issue_metadata(issue)
              |> Map.merge(%{
                class: classify_issue(issue),
                dispatch_source: source,
                dispatch_priority: dispatch_priority(issue, state),
                conflict_keys:
                  issue_conflict_keys(issue, state) |> Logging.normalize_conflict_keys()
              })
            )
          )

          Telemetry.emit_dispatch(
            issue.identifier,
            classify_issue(issue),
            dispatch_priority(issue, state)
          )

          {:ok, dispatch_issue(state, issue, attempt)}

        {:skip, reason} ->
          {:skip, state, reason}
      end
    end
  end

  @spec dispatch_issue(state(), Issue.t(), non_neg_integer()) :: state()
  defp dispatch_issue(state, issue, attempt) do
    state = persist_run_state(state, issue, :claimed, attempt)
    concurrency_class = classify_issue(issue)
    conflict_keys = issue_conflict_keys(issue, state)

    case state.workspace.prepare(issue, state.workspace_opts) do
      {:ok, %{path: workspace_path, reason: prepare_reason}} ->
        log_workspace_prepare(issue, workspace_path, prepare_reason)

        task =
          Task.Supervisor.async_nolink(state.task_supervisor, fn ->
            result =
              case state.workspace.run_lifecycle_hook(
                     :before_run,
                     workspace_path,
                     state.workspace_opts,
                     issue
                   ) do
                :ok ->
                  run_result =
                    state.agent_runner.run(issue,
                      workspace_path: workspace_path,
                      workflow_path: state.workflow_path,
                      codex: state.codex_opts
                    )

                  case state.workspace.run_lifecycle_hook(
                         :after_run,
                         workspace_path,
                         state.workspace_opts,
                         issue
                       ) do
                    :ok ->
                      run_result

                    {:error, reason} ->
                      hook_failure_result(:after_run, reason, run_result)
                  end

                {:error, reason} ->
                  hook_failure_result(:before_run, reason)
              end

            {:issue_finished, issue.identifier, result}
          end)

        state = persist_run_state(state, issue, :running, attempt)
        started_at = DateTime.utc_now()
        started_at_ms = System.system_time(:millisecond)
        started_at_mono_ms = System.monotonic_time(:millisecond)

        put_in(state, [:running, issue.identifier], %{
          issue: issue,
          task: task,
          workspace_path: workspace_path,
          state: :running,
          attempt: attempt,
          concurrency_class: concurrency_class,
          conflict_keys: conflict_keys,
          started_at: started_at,
          started_at_ms: started_at_ms,
          started_at_mono_ms: started_at_mono_ms
        })

      {:error, reason} ->
        Logger.warning(
          "workspace prepare failed",
          Logging.logger_metadata(
            Logging.issue_metadata(issue)
            |> Map.merge(%{
              attempt: attempt,
              class: concurrency_class,
              conflict_keys: Logging.normalize_conflict_keys(conflict_keys),
              workspace_error: inspect(reason)
            })
          )
        )

        queue_retry_or_release(state, issue, attempt, {:error, reason})
    end
  end

  @spec finish_issue(state(), String.t(), term()) :: state()
  defp finish_issue(state, identifier, result) do
    case Map.pop(state.running, identifier) do
      {nil, _running} ->
        state

      {%{workspace_path: workspace_path, issue: issue, attempt: attempt} = running_entry, running} ->
        _ = state.workspace.remove(workspace_path, state.workspace_opts)

        state
        |> Map.put(:running, running)
        |> maybe_retry_or_release(issue, attempt, result, running_entry)
    end
  end

  @spec maybe_retry_or_release(state(), Issue.t(), non_neg_integer(), term(), running_entry()) ::
          state()
  defp maybe_retry_or_release(state, issue, attempt, %{status: :success} = result, running_entry) do
    metadata = completion_metadata(result, running_entry)

    state
    |> maybe_post_completion_summary(issue, metadata)
    |> persist_run_state(
      issue,
      :released,
      attempt,
      Map.merge(%{result: :success}, persisted_completion_metadata(metadata))
    )
    |> clear_issue_retry_state(issue, attempt, metadata)
  end

  defp maybe_retry_or_release(
         state,
         issue,
         attempt,
         %{status: :cancelled} = result,
         running_entry
       ) do
    state
    |> persist_run_state(issue, :released, attempt, %{
      result: :cancelled,
      details: inspect(result)
    })
    |> clear_issue_retry_state(issue, attempt, completion_metadata(result, running_entry))
  end

  defp maybe_retry_or_release(state, issue, attempt, result, _running_entry) do
    queue_retry_or_release(state, issue, attempt, result)
  end

  @spec queue_retry_or_release(state(), Issue.t(), non_neg_integer(), term()) :: state()
  defp queue_retry_or_release(state, issue, attempt, result) do
    next_retry_count = attempt + 1
    concurrency_class = classify_issue(issue)
    conflict_keys = issue_conflict_keys(issue, state)

    if next_retry_count <= state.max_retries do
      backoff_ms = compute_backoff_ms(state, next_retry_count)
      queued_at = DateTime.utc_now()
      queued_at_ms = System.system_time(:millisecond)
      queued_at_mono_ms = System.monotonic_time(:millisecond)
      due_at_ms = queued_at_mono_ms + backoff_ms

      state =
        persist_run_state(state, issue, :retry_queued, next_retry_count, %{
          backoff_ms: backoff_ms,
          details: inspect(result)
        })

      state
      |> put_in([:retry_queue, issue.identifier], %{
        issue: issue,
        attempt: next_retry_count,
        due_at_ms: due_at_ms,
        queued_at: queued_at,
        queued_at_ms: queued_at_ms,
        queued_at_mono_ms: queued_at_mono_ms,
        backoff_ms: backoff_ms,
        last_result: result,
        concurrency_class: concurrency_class,
        conflict_keys: conflict_keys
      })
      |> put_in([:retries, issue.identifier], next_retry_count)
    else
      state
      |> persist_run_state(issue, :released, attempt, %{
        result: :failed,
        details: inspect(result)
      })
      |> clear_issue_retry_state(issue, attempt)
    end
  end

  @spec clear_issue_retry_state(state(), Issue.t(), non_neg_integer(), map()) :: state()
  defp clear_issue_retry_state(state, issue, attempt, metadata \\ %{}) do
    identifier = issue.identifier

    state
    |> update_in([:retry_queue], &Map.delete(&1, identifier))
    |> update_in([:retries], &Map.delete(&1, identifier))
    |> update_in([:last_persisted_payloads], &Map.delete(&1, identifier))
    |> update_in([:deferral_counts], &Map.delete(&1, identifier))
    |> record_completed_issue(issue, attempt, metadata)
    |> mark_issue_completed(identifier)
  end

  @spec mark_issue_completed(state(), String.t()) :: state()
  defp mark_issue_completed(state, identifier) do
    update_in(state.completed_issue_identifiers, &MapSet.put(&1, identifier))
  end

  @spec record_completed_issue(state(), Issue.t(), non_neg_integer(), map()) :: state()
  defp record_completed_issue(state, issue, attempt, metadata) do
    result = Map.get(metadata, :result, completed_result_for_issue(state, issue.identifier))

    entry =
      metadata
      |> Map.merge(%{
        issue: issue,
        attempt: attempt,
        result: result,
        completed_at: DateTime.utc_now()
      })

    update_in(state.completed, fn completed ->
      [entry | Enum.reject(completed, &(&1.issue.identifier == issue.identifier))]
      |> Enum.take(20)
    end)
  end

  @spec completed_result_for_issue(state(), String.t()) :: atom()
  defp completed_result_for_issue(state, identifier) do
    case get_in(state.last_persisted_payloads, [identifier, :result]) do
      result when is_atom(result) -> result
      _other -> :success
    end
  end

  @spec hook_failure_result(:before_run | :after_run, term(), map() | nil) :: map()
  defp hook_failure_result(hook_name, reason, result \\ nil) do
    error = "#{hook_name} hook failed: #{inspect(reason)}"

    base = %{
      status: :error,
      summary: error,
      outcome_kind: :blocked,
      error: error,
      error_category: "#{hook_name}_hook_failed"
    }

    case result do
      %{} = run_result -> Map.merge(run_result, base)
      _ -> base
    end
  end

  @spec cleanup_inactive_worktrees(state()) :: state()
  defp cleanup_inactive_worktrees(state) do
    if function_exported?(state.workspace, :cleanup_inactive_worktrees, 1) do
      state.workspace.cleanup_inactive_worktrees(
        Keyword.merge(state.workspace_opts,
          tracker: state.tracker,
          tracker_opts: state.tracker_opts,
          active_issue_identifiers: Map.keys(state.running)
        )
      )
    end

    state
  end

  @spec completion_metadata(map(), running_entry()) :: map()
  defp completion_metadata(result, running_entry) do
    %{
      result: result.status,
      workspace_path: running_entry.workspace_path,
      started_at: running_entry.started_at,
      started_at_ms: running_entry.started_at_ms,
      elapsed_ms: result[:elapsed_ms],
      thread_id: result[:thread_id],
      turn_id: result[:turn_id],
      session_id: result[:session_id],
      recovery_count: result[:recovery_count] || 0,
      last_event: result[:last_event],
      last_message: result[:last_message],
      error: result[:error],
      error_category: result[:error_category]
    }
  end

  @spec maybe_post_completion_summary(state(), Issue.t(), map()) :: state()
  defp maybe_post_completion_summary(state, issue, metadata) do
    case completion_summary_comment_body(metadata) do
      nil ->
        state

      body ->
        case state.tracker.create_comment(issue.identifier, body, state.tracker_opts) do
          {:ok, _response} -> state
          {:error, _reason} -> state
        end
    end
  end

  @spec persisted_completion_metadata(map()) :: map()
  defp persisted_completion_metadata(metadata) do
    Map.take(metadata, [
      :elapsed_ms,
      :thread_id,
      :turn_id,
      :session_id,
      :recovery_count,
      :last_event,
      :error,
      :error_category
    ])
  end

  @spec completion_summary_comment_body(map()) :: String.t() | nil
  defp completion_summary_comment_body(metadata) do
    case metadata[:last_message] do
      message when is_binary(message) ->
        trimmed = String.trim(message)

        if trimmed == "" do
          nil
        else
          [
            "## Symphony 작업 요약",
            trimmed
          ]
          |> Enum.join("\n\n")
        end

      _ ->
        nil
    end
  end

  @spec publish_snapshot(map()) :: map()
  defp publish_snapshot(state) do
    fingerprint = RuntimeSnapshot.observer_fingerprint(state)

    if state.last_runtime_snapshot_fingerprint == fingerprint do
      state
    else
      state
      |> RuntimeSnapshot.from_state()
      |> Dashboard.broadcast_snapshot()

      Map.put(state, :last_runtime_snapshot_fingerprint, fingerprint)
    end
  end

  @spec explicit_issue_identifier(keyword(), keyword()) :: String.t() | nil
  defp explicit_issue_identifier(opts, tracker_opts) do
    Keyword.get(opts, :issue_identifier) ||
      get_in(opts, [:orchestrator, :issue_identifier]) ||
      Keyword.get(tracker_opts, :issue_identifier)
  end

  @spec blocked_labels(keyword()) :: MapSet.t(String.t())
  defp blocked_labels(opts) do
    opts
    |> Keyword.get(:blocked_labels, @default_blocked_labels)
    |> Enum.map(&normalize_label/1)
    |> MapSet.new()
  end

  @spec concurrency_limits(keyword()) :: %{concurrency_class() => pos_integer()}
  defp concurrency_limits(opts) do
    opts
    |> Keyword.get(:concurrency_limits, @default_concurrency_limits)
    |> Enum.reduce(%{}, fn {klass, limit}, acc ->
      case normalize_class(klass) do
        nil -> acc
        normalized -> Map.put(acc, normalized, limit)
      end
    end)
  end

  @spec serialization_label_prefixes(keyword()) :: [String.t()]
  defp serialization_label_prefixes(opts) do
    opts
    |> Keyword.get(:serialization_label_prefixes, @default_serialization_label_prefixes)
    |> Enum.map(&normalize_label/1)
  end

  @spec available_slots(state()) :: non_neg_integer()
  defp available_slots(state), do: max(state.max_concurrent - map_size(state.running), 0)

  @spec dispatch_eligibility(state(), Issue.t()) :: :ok | {:skip, atom()}
  defp dispatch_eligibility(state, %Issue{} = issue) do
    with :ok <- check_issue_basics(issue),
         :ok <- check_issue_not_duplicate(state, issue),
         :ok <- check_issue_not_blocked(state, issue) do
      if class_slots_available?(state, classify_issue(issue)),
        do: :ok,
        else: {:skip, :class_saturated}
    end
  end

  @spec check_issue_basics(Issue.t()) :: :ok | {:skip, atom()}
  defp check_issue_basics(issue) do
    cond do
      not runnable_issue_state?(issue.state) -> {:skip, :inactive_state}
      String.trim(issue.title || "") == "" -> {:skip, :missing_title}
      true -> :ok
    end
  end

  @spec check_issue_not_duplicate(state(), Issue.t()) :: :ok | {:skip, atom()}
  defp check_issue_not_duplicate(state, issue) do
    cond do
      MapSet.member?(state.completed_issue_identifiers, issue.identifier) ->
        {:skip, :already_completed}

      Map.has_key?(state.running, issue.identifier) ->
        {:skip, :already_running}

      Map.has_key?(state.retry_queue, issue.identifier) ->
        {:skip, :retry_queued}

      true ->
        :ok
    end
  end

  @spec check_issue_not_blocked(state(), Issue.t()) :: :ok | {:skip, atom()}
  defp check_issue_not_blocked(state, issue) do
    cond do
      blocked_issue?(issue, state.blocked_labels) -> {:skip, :human_blocked}
      dependency_blocked?(issue) -> {:skip, :dependency_blocked}
      missing_required_metadata?(issue) -> {:skip, :missing_required_metadata}
      conflict_locked?(state, issue) -> {:skip, :serialized_conflict}
      true -> :ok
    end
  end

  @spec dependency_blocked?(Issue.t()) :: boolean()
  defp dependency_blocked?(%Issue{} = issue), do: issue.blocked_by_identifiers != []

  @spec missing_required_metadata?(Issue.t()) :: boolean()
  defp missing_required_metadata?(%Issue{} = issue), do: issue.missing_required_fields != []

  @spec prioritize_candidates([Issue.t()], state()) :: {[Issue.t()], state()}
  defp prioritize_candidates(issues, state) do
    {eligible, state} =
      Enum.reduce(issues, {[], state}, fn issue, {eligible, acc} ->
        case dispatch_eligibility(acc, issue) do
          :ok ->
            {[issue | eligible], acc}

          {:skip, reason} ->
            {eligible, note_gated_issue(acc, issue, reason, classify_issue(issue))}
        end
      end)

    eligible = Enum.reverse(eligible)

    next_deferral_counts =
      eligible
      |> Enum.map(& &1.identifier)
      |> MapSet.new()
      |> then(fn eligible_ids ->
        state.deferral_counts
        |> Map.take(MapSet.to_list(eligible_ids))
        |> Enum.into(%{}, fn {identifier, count} -> {identifier, count + 1} end)
      end)

    prioritized = Enum.sort_by(eligible, &candidate_sort_key(&1, state))

    next_state =
      case prioritized do
        [%Issue{identifier: dispatched_identifier} | _rest] ->
          put_in(state.deferral_counts, Map.delete(next_deferral_counts, dispatched_identifier))

        [] ->
          put_in(state.deferral_counts, %{})
      end

    {prioritized, next_state}
  end

  @spec candidate_sort_key(Issue.t(), state()) :: {integer(), integer(), integer()}
  defp candidate_sort_key(issue, state) do
    {-dispatch_priority(issue, state), class_rank(classify_issue(issue)),
     normalized_issue_number(issue)}
  end

  @spec retry_sort_key(Issue.t(), integer(), state()) ::
          {integer(), integer(), integer(), integer()}
  defp retry_sort_key(issue, due_at_ms, state) do
    {due_at_ms, -dispatch_priority(issue, state), class_rank(classify_issue(issue)),
     normalized_issue_number(issue)}
  end

  @spec dispatch_priority(Issue.t(), state()) :: integer()
  defp dispatch_priority(%Issue{} = issue, state) do
    issue.priority + label_priority_bonus(issue.labels) + starvation_bonus(issue, state)
  end

  @spec label_priority_bonus([String.t()]) :: integer()
  defp label_priority_bonus(labels) do
    normalized = Enum.map(labels, &normalize_label/1)

    Enum.reduce(normalized, 0, fn label, acc ->
      acc +
        cond do
          label in ["severity:critical", "sev:0", "p0", "priority:0"] -> 100
          label in ["severity:high", "sev:1", "p1", "priority:1"] -> 50
          label in ["severity:medium", "sev:2", "p2", "priority:2"] -> 20
          label in ["priority:3", "p3"] -> 5
          true -> 0
        end
    end)
  end

  @spec starvation_bonus(Issue.t(), state()) :: integer()
  defp starvation_bonus(%Issue{} = issue, state) do
    count = Map.get(state.deferral_counts, issue.identifier, 0)
    step = Keyword.get(state.tracker_opts, :starvation_bonus_step, @default_starvation_bonus_step)
    cap = Keyword.get(state.tracker_opts, :starvation_bonus_cap, @default_starvation_bonus_cap)
    min(count * step, cap)
  end

  @spec classify_issue(Issue.t()) :: concurrency_class()
  defp classify_issue(%Issue{} = issue) do
    labels = Enum.map(issue.labels, &normalize_label/1)
    title = normalize_label(issue.title)

    cond do
      Enum.any?(labels, &(&1 in ["docs", "documentation", "type:docs", "area:docs"])) ->
        :docs

      Enum.any?(labels, &(&1 in ["infra", "infrastructure", "ops", "devops", "type:infra"])) ->
        :infra

      Enum.any?(labels, &(&1 in ["code", "bug", "feature", "enhancement", "type:code"])) ->
        :code

      String.contains?(title, "docs") or String.contains?(title, "readme") ->
        :docs

      true ->
        :default
    end
  end

  @spec issue_conflict_keys(Issue.t(), state()) :: MapSet.t(conflict_key())
  defp issue_conflict_keys(%Issue{} = issue, state) do
    label_keys =
      issue.labels
      |> Enum.map(&normalize_label/1)
      |> Enum.filter(&serialization_label?(&1, state.serialization_label_prefixes))

    hint_keys =
      issue.conflict_hints
      |> Enum.map(&normalize_label/1)
      |> Enum.filter(&serialization_label?(&1, state.serialization_label_prefixes))

    keys =
      (label_keys ++ hint_keys)
      |> Enum.uniq()
      |> case do
        [] when state.default_conflict_scope_to_class ->
          ["class:" <> Atom.to_string(classify_issue(issue))]

        collected ->
          collected
      end

    MapSet.new(keys)
  end

  @spec serialization_label?(String.t(), [String.t()]) :: boolean()
  defp serialization_label?(label, prefixes) do
    Enum.any?(prefixes, &String.starts_with?(label, &1))
  end

  @spec conflict_locked?(state(), Issue.t()) :: boolean()
  defp conflict_locked?(state, issue) do
    issue_keys = issue_conflict_keys(issue, state)

    Enum.any?(Map.values(state.running), fn running ->
      running.issue.identifier != issue.identifier and
        not MapSet.disjoint?(running.conflict_keys, issue_keys)
    end)
  end

  @spec class_rank(concurrency_class()) :: non_neg_integer()
  defp class_rank(:infra), do: 0
  defp class_rank(:code), do: 1
  defp class_rank(:docs), do: 2
  defp class_rank(_other), do: 3

  @spec class_slots_available?(state(), concurrency_class()) :: boolean()
  defp class_slots_available?(state, klass) do
    running_count =
      state.running
      |> Map.values()
      |> Enum.count(&(&1.concurrency_class == klass))

    running_count < Map.get(state.concurrency_limits, klass, state.max_concurrent)
  end

  @spec blocked_issue?(Issue.t(), MapSet.t(String.t())) :: boolean()
  defp blocked_issue?(%Issue{} = issue, blocked_labels) do
    issue.labels
    |> Enum.map(&normalize_label/1)
    |> Enum.any?(&MapSet.member?(blocked_labels, &1))
  end

  @spec runnable_issue_state?(String.t()) :: boolean()
  defp runnable_issue_state?(state) when is_binary(state) do
    normalized = normalize_label(state)
    normalized not in ["done", "closed", "cancelled", "canceled", "released"]
  end

  defp runnable_issue_state?(_state), do: true

  @spec normalized_issue_number(Issue.t()) :: integer()
  defp normalized_issue_number(%Issue{identifier: identifier}) do
    identifier
    |> to_string()
    |> String.replace(~r/[^0-9]/, "")
    |> case do
      "" -> 0
      digits -> String.to_integer(digits)
    end
  end

  @spec normalize_label(term()) :: String.t()
  defp normalize_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec normalize_class(atom() | String.t()) :: concurrency_class() | nil
  defp normalize_class(value) when is_atom(value) do
    if value in [:default, :code, :docs, :infra], do: value, else: nil
  end

  defp normalize_class(value) do
    case value |> to_string() |> String.trim() |> String.downcase() |> String.replace("-", "_") do
      "default" -> :default
      "code" -> :code
      "docs" -> :docs
      "infra" -> :infra
      _ -> nil
    end
  end

  @spec compute_backoff_ms(state(), pos_integer()) :: pos_integer()
  defp compute_backoff_ms(state, attempt) do
    multiplier = Integer.pow(2, attempt - 1)
    min(state.retry_backoff_ms * multiplier, state.max_retry_backoff_ms)
  end

  @spec persist_run_state(state(), Issue.t(), run_state(), non_neg_integer(), map()) :: state()
  defp persist_run_state(state, issue, run_state, attempt, metadata \\ %{}) do
    payload = Map.merge(%{status: run_state, attempt: attempt}, metadata)

    if Map.get(state.last_persisted_payloads, issue.identifier) == payload do
      state
    else
      case state.tracker.write_run_record(issue, payload, state.tracker_opts) do
        {:ok, _} ->
          Telemetry.emit_write_back(issue.identifier, tracker_kind(state))
          put_in(state, [:last_persisted_payloads, issue.identifier], payload)

        {:error, reason} ->
          Logger.warning(
            "tracker write-back failed",
            Logging.logger_metadata(
              Logging.issue_metadata(issue)
              |> Map.merge(%{status: run_state, attempt: attempt, tracker_error: inspect(reason)})
            )
          )

          state
      end
    end
  end

  @spec log_workspace_prepare(Issue.t(), String.t(), term()) :: :ok
  defp log_workspace_prepare(issue, workspace_path, {:recover, session}) do
    Logger.info(
      "workspace prepared",
      Logging.merge_logger_metadata([
        Logging.issue_metadata(issue),
        Logging.session_metadata(session),
        %{workspace_path: workspace_path, prepare_reason: "recover"}
      ])
    )
  end

  defp log_workspace_prepare(issue, workspace_path, reason) do
    Logger.debug(
      "workspace prepared",
      Logging.logger_metadata(
        Logging.issue_metadata(issue)
        |> Map.merge(%{workspace_path: workspace_path, prepare_reason: inspect(reason)})
      )
    )
  end

  @spec tracker_kind(state()) :: atom()
  defp tracker_kind(%{tracker: tracker}) do
    case tracker do
      SymphonyEx.GitHub.Adapter -> :github
      other -> other
    end
  end

  @spec log_gated_issue(state(), Issue.t(), atom(), concurrency_class()) :: :ok
  defp log_gated_issue(state, issue, reason, klass) do
    Logger.debug(
      "issue gated",
      Logging.logger_metadata(
        Logging.dispatch_metadata(issue, reason, klass, issue_conflict_keys(issue, state))
      )
    )
  end

  @spec note_gated_issue(state(), Issue.t(), atom(), concurrency_class()) :: state()
  defp note_gated_issue(state, issue, reason, klass) do
    log_gated_issue(state, issue, reason, klass)

    if reason in @github_visible_gating_reasons do
      persist_gated_issue(state, issue, reason, klass)
    else
      state
    end
  end

  @spec persist_gated_issue(state(), Issue.t(), atom(), concurrency_class()) :: state()
  defp persist_gated_issue(state, issue, reason, klass) do
    payload =
      %{
        status: :gated,
        attempt: Map.get(state.retries, issue.identifier, 0),
        gating_reason: reason,
        class: klass,
        conflict_keys: issue_conflict_keys(issue, state) |> Logging.normalize_conflict_keys()
      }
      |> maybe_put_gating_context(issue, reason)

    if Map.get(state.last_persisted_payloads, issue.identifier) == payload do
      state
    else
      case state.tracker.write_run_record(issue, payload, state.tracker_opts) do
        {:ok, _} ->
          put_in(state, [:last_persisted_payloads, issue.identifier], payload)

        {:error, reason_value} ->
          Logger.warning(
            "tracker gated write-back failed",
            Logging.logger_metadata(
              Logging.issue_metadata(issue)
              |> Map.merge(%{
                gating_reason: reason,
                class: klass,
                tracker_error: inspect(reason_value)
              })
            )
          )

          state
      end
    end
  end

  @spec maybe_put_gating_context(map(), Issue.t(), atom()) :: map()
  defp maybe_put_gating_context(payload, %Issue{} = issue, :missing_required_metadata) do
    Map.put(payload, :missing_required_fields, issue.missing_required_fields)
  end

  defp maybe_put_gating_context(payload, %Issue{} = issue, :dependency_blocked) do
    Map.put(payload, :blocked_by_identifiers, issue.blocked_by_identifiers)
  end

  defp maybe_put_gating_context(payload, _issue, _reason), do: payload
end
