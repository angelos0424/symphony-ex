defmodule SymphonyEx.RuntimeSnapshot do
  @moduledoc """
  Normalizes orchestrator runtime state into a dashboard/API-friendly snapshot.

  This keeps the Phoenix layer thin and gives future LiveView updates a stable,
  bounded payload shape to consume.
  """

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.{Observability, Orchestrator}
  alias SymphonyEx.RunEventLogger
  alias SymphonyEx.SessionStore

  @log_tail_limit 5
  @detail_event_limit 25

  @type log_event :: %{
          event: String.t() | nil,
          timestamp: String.t() | nil,
          message: String.t() | nil,
          raw_method: String.t() | nil,
          status: String.t() | nil
        }

  @type log_excerpt :: %{
          path: String.t() | nil,
          exists: boolean(),
          event_count: non_neg_integer(),
          recent_events: [log_event()]
        }

  @type session_excerpt :: %{
          path: String.t() | nil,
          exists: boolean(),
          data: map() | nil
        }

  @type debug_excerpt :: %{
          dir: String.t() | nil,
          exists: boolean(),
          files: [String.t()]
        }

  @type completed_entry :: %{
          issue: map(),
          attempt: non_neg_integer(),
          result: atom(),
          completed_at: String.t(),
          elapsed_ms: non_neg_integer() | nil,
          workspace_path: String.t() | nil,
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          session_id: String.t() | nil,
          recovery_count: non_neg_integer(),
          last_event: String.t() | nil,
          last_message: String.t() | nil,
          error: String.t() | nil,
          error_category: String.t() | nil,
          log_excerpt: log_excerpt()
        }

  @type detailed_run :: map()

  @type snapshot :: %{
          summary: map(),
          running: [map()],
          retry_queue: [map()],
          completed: [completed_entry()],
          completed_issue_identifiers: [String.t()],
          settings: map()
        }

  @type observer_fingerprint :: integer()

  @spec from_orchestrator(GenServer.server()) :: snapshot()
  def from_orchestrator(server \\ Orchestrator) do
    try do
      server
      |> Orchestrator.snapshot()
      |> from_state()
    catch
      :exit, _reason -> empty_snapshot()
    end
  end

  @spec from_state(map()) :: snapshot()
  def from_state(state) do
    running = running_entries(state)
    retry_queue = retry_entries(state)
    completed = completed_entries(state)

    %{
      summary:
        summary_payload(
          running,
          retry_queue,
          completed,
          state.max_concurrent,
          map_size(state.running)
        ),
      running: running,
      retry_queue: retry_queue,
      completed: completed,
      completed_issue_identifiers:
        completed |> Enum.map(& &1.issue.identifier) |> Enum.uniq() |> Enum.sort(),
      settings: %{
        poll_interval_ms: state.poll_interval_ms,
        max_concurrent: state.max_concurrent,
        max_retries: state.max_retries,
        retry_backoff_ms: state.retry_backoff_ms,
        max_retry_backoff_ms: state.max_retry_backoff_ms,
        concurrency_limits: normalize_concurrency_limits(state.concurrency_limits),
        blocked_labels: state.blocked_labels |> MapSet.to_list() |> Enum.sort(),
        serialization_label_prefixes: Enum.sort(state.serialization_label_prefixes),
        explicit_issue_identifier: state.explicit_issue_identifier,
        workflow_path: state.workflow_path
      }
    }
  end

  @spec observer_fingerprint(map()) :: observer_fingerprint()
  def observer_fingerprint(state) do
    :erlang.phash2(
      {:runtime_snapshot_v1, observer_running(state), observer_retry_queue(state),
       observer_completed(state), observer_settings(state), Observability.snapshot()}
    )
  end

  @spec find_run(snapshot(), String.t()) :: map() | nil
  def find_run(snapshot, identifier) do
    Enum.find_value(snapshot.running, fn running ->
      if get_in(running, [:issue, :identifier]) == identifier,
        do: Map.put(running, :queue, :running),
        else: nil
    end) ||
      Enum.find_value(snapshot.retry_queue, fn retry ->
        if get_in(retry, [:issue, :identifier]) == identifier,
          do: Map.put(retry, :queue, :retry_queue),
          else: nil
      end) ||
      Enum.find_value(snapshot.completed, fn completed ->
        if get_in(completed, [:issue, :identifier]) == identifier,
          do: Map.put(completed, :queue, :completed),
          else: nil
      end)
  end

  @spec run_detail(snapshot(), String.t()) :: detailed_run() | nil
  def run_detail(snapshot, identifier) do
    case find_run(snapshot, identifier) do
      nil -> nil
      run -> enrich_run(run)
    end
  end

  @spec summary_payload(
          [map()],
          [map()],
          [completed_entry()],
          non_neg_integer(),
          non_neg_integer()
        ) :: map()
  defp summary_payload(running, retry_queue, completed, max_concurrent, running_count) do
    success_count = Enum.count(completed, &(&1.result == :success))
    failed_count = Enum.count(completed, &(&1.result == :failed))
    cancelled_count = Enum.count(completed, &(&1.result == :cancelled))
    avg_runtime_ms = average(Enum.map(completed, & &1.elapsed_ms))

    %{
      running_count: length(running),
      retry_queue_count: length(retry_queue),
      completed_count: length(completed),
      success_count: success_count,
      failed_count: failed_count,
      cancelled_count: cancelled_count,
      success_rate: percentage(success_count, length(completed)),
      average_runtime_ms: avg_runtime_ms,
      available_slots: max(max_concurrent - running_count, 0),
      max_concurrent: max_concurrent,
      rate_limits: Observability.snapshot()
    }
  end

  defp observer_running(state) do
    state.running
    |> Map.values()
    |> Enum.map(fn entry ->
      %{
        identifier: entry.issue.identifier,
        state: entry.state,
        attempt: entry.attempt,
        workspace_path: entry.workspace_path,
        concurrency_class: entry.concurrency_class,
        conflict_keys: entry.conflict_keys |> MapSet.to_list() |> Enum.sort(),
        started_at_ms: entry.started_at_ms
      }
    end)
    |> Enum.sort_by(fn entry -> {entry.concurrency_class, entry.identifier} end)
  end

  defp observer_retry_queue(state) do
    state.retry_queue
    |> Map.values()
    |> Enum.map(fn entry ->
      %{
        identifier: entry.issue.identifier,
        attempt: entry.attempt,
        due_at_ms: entry.due_at_ms,
        backoff_ms: entry.backoff_ms,
        concurrency_class: entry.concurrency_class,
        conflict_keys: entry.conflict_keys |> MapSet.to_list() |> Enum.sort(),
        last_result: observer_last_result(entry.last_result)
      }
    end)
    |> Enum.sort_by(fn entry -> {entry.due_at_ms, entry.concurrency_class, entry.identifier} end)
  end

  defp observer_completed(state) do
    state.completed
    |> Enum.map(fn entry ->
      %{
        identifier: observer_issue_identifier(Map.get(entry, :issue)),
        attempt: Map.get(entry, :attempt),
        result: Map.get(entry, :result),
        completed_at: Map.get(entry, :completed_at),
        started_at: Map.get(entry, :started_at),
        elapsed_ms: Map.get(entry, :elapsed_ms),
        workspace_path: Map.get(entry, :workspace_path),
        thread_id: Map.get(entry, :thread_id),
        turn_id: Map.get(entry, :turn_id),
        session_id: Map.get(entry, :session_id),
        recovery_count: Map.get(entry, :recovery_count),
        last_event: Map.get(entry, :last_event),
        last_message: Map.get(entry, :last_message),
        error: Map.get(entry, :error),
        error_category: Map.get(entry, :error_category)
      }
    end)
    |> Enum.sort_by(& &1.identifier)
  end

  defp observer_settings(state) do
    %{
      poll_interval_ms: state.poll_interval_ms,
      max_concurrent: state.max_concurrent,
      max_retries: state.max_retries,
      retry_backoff_ms: state.retry_backoff_ms,
      max_retry_backoff_ms: state.max_retry_backoff_ms,
      concurrency_limits: normalize_concurrency_limits(state.concurrency_limits),
      blocked_labels: state.blocked_labels |> MapSet.to_list() |> Enum.sort(),
      serialization_label_prefixes: Enum.sort(state.serialization_label_prefixes),
      explicit_issue_identifier: state.explicit_issue_identifier,
      workflow_path: state.workflow_path
    }
  end

  defp observer_last_result(result) when is_map(result) do
    Map.take(result, [:status, :error, :error_category, :last_event, :last_message, :elapsed_ms])
  end

  defp observer_last_result(_other), do: nil

  defp observer_issue_identifier(%Issue{identifier: identifier}), do: identifier
  defp observer_issue_identifier(%{identifier: identifier}), do: identifier
  defp observer_issue_identifier(_other), do: nil

  @spec running_entries(map()) :: [map()]
  def running_entries(state) do
    now_system_ms = System.system_time(:millisecond)
    now_mono_ms = System.monotonic_time(:millisecond)

    state.running
    |> Map.values()
    |> Enum.sort_by(fn entry -> {class_rank(entry.concurrency_class), entry.issue.identifier} end)
    |> Enum.map(fn entry ->
      %{
        issue: issue_payload(entry.issue),
        workspace_path: entry.workspace_path,
        state: entry.state,
        attempt: entry.attempt,
        concurrency_class: entry.concurrency_class,
        conflict_keys: entry.conflict_keys |> MapSet.to_list() |> Enum.sort(),
        task_ref: inspect(entry.task.ref),
        task_pid: inspect(entry.task.pid),
        started_at: DateTime.to_iso8601(entry.started_at),
        started_at_ms: entry.started_at_ms,
        elapsed_ms: max(now_mono_ms - entry.started_at_mono_ms, 0),
        elapsed_seconds: Float.round(max(now_system_ms - entry.started_at_ms, 0) / 1_000, 1),
        log_excerpt: log_excerpt(entry.workspace_path)
      }
    end)
  end

  @spec retry_entries(map()) :: [map()]
  def retry_entries(state) do
    now_system_ms = System.system_time(:millisecond)
    now_mono_ms = System.monotonic_time(:millisecond)

    state.retry_queue
    |> Map.values()
    |> Enum.sort_by(fn entry ->
      {entry.due_at_ms, class_rank(entry.concurrency_class), entry.issue.identifier}
    end)
    |> Enum.map(fn entry ->
      due_in_ms = max(entry.due_at_ms - now_mono_ms, 0)

      %{
        issue: issue_payload(entry.issue),
        attempt: entry.attempt,
        due_at_ms: entry.due_at_ms,
        due_at: unix_ms_to_iso8601(now_system_ms + due_in_ms),
        due_in_ms: due_in_ms,
        queued_at: DateTime.to_iso8601(entry.queued_at),
        queued_at_ms: entry.queued_at_ms,
        queued_for_ms: max(now_mono_ms - entry.queued_at_mono_ms, 0),
        backoff_ms: entry.backoff_ms,
        concurrency_class: entry.concurrency_class,
        conflict_keys: entry.conflict_keys |> MapSet.to_list() |> Enum.sort(),
        last_result: result_payload(entry.last_result),
        log_excerpt: log_excerpt(entry[:workspace_path]),
        workspace_path: entry[:workspace_path]
      }
    end)
  end

  @spec completed_entries(map()) :: [completed_entry()]
  def completed_entries(state) do
    state.completed
    |> Enum.sort_by(& &1.completed_at, {:desc, DateTime})
    |> Enum.map(fn entry ->
      workspace_path = entry[:workspace_path]

      %{
        issue: issue_payload(entry.issue),
        attempt: entry.attempt,
        result: entry.result,
        completed_at: DateTime.to_iso8601(entry.completed_at),
        elapsed_ms: entry[:elapsed_ms],
        workspace_path: workspace_path,
        started_at: iso8601_or_nil(entry[:started_at]),
        thread_id: entry[:thread_id],
        turn_id: entry[:turn_id],
        session_id: entry[:session_id],
        recovery_count: entry[:recovery_count] || 0,
        last_event: entry[:last_event],
        last_message: entry[:last_message],
        error: entry[:error],
        error_category: entry[:error_category],
        log_excerpt: log_excerpt(workspace_path)
      }
    end)
  end

  @spec issue_payload(Issue.t()) :: map()
  def issue_payload(%Issue{} = issue) do
    %{
      id: issue.id,
      identifier: issue.identifier,
      title: issue.title,
      state: issue.state,
      priority: issue.priority,
      labels: Enum.sort(issue.labels),
      assignees: Enum.sort(issue.assignees),
      conflict_hints: Enum.sort(issue.conflict_hints),
      url: issue.url,
      parent_id: issue.parent_id,
      children_ids: Enum.sort(issue.children_ids)
    }
  end

  @spec enrich_run(map()) :: detailed_run()
  defp enrich_run(run) do
    workspace_path = Map.get(run, :workspace_path)
    paths = run_paths(workspace_path)

    run
    |> Map.put(:paths, paths)
    |> Map.put(:session_excerpt, session_excerpt(workspace_path))
    |> Map.put(:debug_excerpt, debug_excerpt(paths.debug_dir))
    |> Map.put(:log_timeline, log_timeline(workspace_path))
  end

  @spec normalize_concurrency_limits(map()) :: map()
  defp normalize_concurrency_limits(limits) do
    limits
    |> Enum.map(fn {klass, limit} -> {Atom.to_string(klass), limit} end)
    |> Enum.sort()
    |> Map.new()
  end

  @spec result_payload(term()) :: map()
  defp result_payload(%{status: status} = result) do
    %{
      status: status,
      error: result[:error],
      error_category: result[:error_category],
      last_event: result[:last_event],
      last_message: result[:last_message],
      thread_id: result[:thread_id],
      turn_id: result[:turn_id],
      session_id: result[:session_id],
      recovery_count: result[:recovery_count] || 0,
      elapsed_ms: result[:elapsed_ms]
    }
  end

  defp result_payload(other), do: %{details: inspect(other)}

  @spec run_paths(Path.t() | nil) :: map()
  defp run_paths(nil) do
    %{workspace: nil, events: nil, session: nil, debug_dir: nil}
  end

  defp run_paths(workspace_path) do
    %{
      workspace: workspace_path,
      events: RunEventLogger.events_path(workspace_path),
      session: SessionStore.session_path(workspace_path),
      debug_dir: Path.join([workspace_path, ".symphony", "debug"])
    }
  end

  @spec log_excerpt(Path.t() | nil) :: log_excerpt()
  defp log_excerpt(nil), do: %{path: nil, exists: false, event_count: 0, recent_events: []}

  defp log_excerpt(workspace_path) do
    path = RunEventLogger.events_path(workspace_path)

    case load_log_events(path) do
      {:ok, events} ->
        %{
          path: path,
          exists: true,
          event_count: length(events),
          recent_events: events |> Enum.take(-@log_tail_limit)
        }

      {:error, _reason} ->
        %{path: path, exists: false, event_count: 0, recent_events: []}
    end
  end

  @spec log_timeline(Path.t() | nil) :: log_excerpt()
  defp log_timeline(nil), do: %{path: nil, exists: false, event_count: 0, recent_events: []}

  defp log_timeline(workspace_path) do
    path = RunEventLogger.events_path(workspace_path)

    case load_log_events(path) do
      {:ok, events} ->
        %{
          path: path,
          exists: true,
          event_count: length(events),
          recent_events: events |> Enum.take(-@detail_event_limit)
        }

      {:error, _reason} ->
        %{path: path, exists: false, event_count: 0, recent_events: []}
    end
  end

  @spec session_excerpt(Path.t() | nil) :: session_excerpt()
  defp session_excerpt(nil), do: %{path: nil, exists: false, data: nil}

  defp session_excerpt(workspace_path) do
    path = SessionStore.session_path(workspace_path)

    case SessionStore.load(workspace_path) do
      {:ok, nil} -> %{path: path, exists: false, data: nil}
      {:ok, data} -> %{path: path, exists: true, data: normalize_session_data(data)}
      {:error, _reason} -> %{path: path, exists: false, data: nil}
    end
  end

  @spec normalize_session_data(map()) :: map()
  defp normalize_session_data(data) do
    %{
      thread_id: data[:thread_id],
      turn_id: data[:turn_id],
      session_id: data[:session_id],
      issue_id: data[:issue_id],
      issue_identifier: data[:issue_identifier],
      turns_executed: data[:turns_executed],
      recovery_count: data[:recovery_count],
      last_event: data[:last_event],
      phase: data[:phase],
      error: data[:error],
      error_category: data[:error_category],
      updated_at: data[:updated_at],
      capability_profile: data[:capability_profile]
    }
  end

  @spec debug_excerpt(Path.t() | nil) :: debug_excerpt()
  defp debug_excerpt(nil), do: %{dir: nil, exists: false, files: []}

  defp debug_excerpt(dir) do
    case File.ls(dir) do
      {:ok, files} ->
        %{
          dir: dir,
          exists: true,
          files: files |> Enum.sort() |> Enum.take(20)
        }

      {:error, _reason} ->
        %{dir: dir, exists: false, files: []}
    end
  end

  @spec load_log_events(Path.t()) :: {:ok, [log_event()]} | {:error, term()}
  defp load_log_events(path) do
    case File.read(path) do
      {:ok, contents} ->
        events =
          contents
          |> String.split("\n", trim: true)
          |> Enum.map(&decode_log_line/1)

        {:ok, events}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec decode_log_line(String.t()) :: log_event()
  defp decode_log_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} when is_map(decoded) ->
        %{
          event: decoded["event"],
          timestamp: decoded["timestamp"] || decoded["event_timestamp"],
          message: decoded["message"],
          raw_method: decoded["raw_method"],
          status: decoded["status"]
        }

      _other ->
        %{
          event: "invalid",
          timestamp: nil,
          message: String.slice(line, 0, 120),
          raw_method: nil,
          status: nil
        }
    end
  end

  @spec unix_ms_to_iso8601(integer()) :: String.t()
  defp unix_ms_to_iso8601(ms) do
    ms
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  @spec average([number() | nil]) :: float() | nil
  defp average(values) do
    numeric = Enum.reject(values, &is_nil/1)

    case numeric do
      [] -> nil
      _ -> Float.round(Enum.sum(numeric) / length(numeric), 1)
    end
  end

  @spec percentage(non_neg_integer(), non_neg_integer()) :: float() | nil
  defp percentage(_count, 0), do: nil
  defp percentage(count, total), do: Float.round(count / total * 100, 1)

  @spec iso8601_or_nil(DateTime.t() | String.t() | nil) :: String.t() | nil
  defp iso8601_or_nil(nil), do: nil
  defp iso8601_or_nil(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp iso8601_or_nil(value), do: to_string(value)

  @spec empty_snapshot() :: snapshot()
  defp empty_snapshot do
    %{
      summary: %{
        running_count: 0,
        retry_queue_count: 0,
        completed_count: 0,
        success_count: 0,
        failed_count: 0,
        cancelled_count: 0,
        success_rate: nil,
        average_runtime_ms: nil,
        available_slots: 0,
        max_concurrent: 0,
        rate_limits: Observability.snapshot()
      },
      running: [],
      retry_queue: [],
      completed: [],
      completed_issue_identifiers: [],
      settings: %{
        poll_interval_ms: 0,
        max_concurrent: 0,
        max_retries: 0,
        retry_backoff_ms: 0,
        max_retry_backoff_ms: 0,
        concurrency_limits: %{},
        blocked_labels: [],
        serialization_label_prefixes: [],
        explicit_issue_identifier: nil,
        workflow_path: nil
      }
    }
  end

  @spec class_rank(atom()) :: non_neg_integer()
  defp class_rank(:infra), do: 0
  defp class_rank(:code), do: 1
  defp class_rank(:docs), do: 2
  defp class_rank(_other), do: 3
end
