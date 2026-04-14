defmodule SymphonyEx.Telemetry do
  @moduledoc """
  Emits `:telemetry` events for key Symphony operations.

  External handlers can attach via `:telemetry.attach/4` or
  `:telemetry.attach_many/4`. No default handlers are registered —
  this module only emits events.

  ## Events

    * `[:symphony_ex, :dispatch]` — an issue was dispatched for execution
    * `[:symphony_ex, :turn, :completed]` — a single agent turn finished
    * `[:symphony_ex, :write_back]` — a run-state record was written to the tracker
    * `[:symphony_ex, :write_back, :stage]` — a write-back stage succeeded, failed, or partially completed
    * `[:symphony_ex, :run, :finished]` — an agent run completed (success or failure)
    * `[:symphony_ex, :rate_limit]` — an external tracker API reported rate-limit state
  """

  @doc """
  Emits `[:symphony_ex, :dispatch]` when an issue is dispatched.
  """
  @spec emit_dispatch(String.t(), atom(), number()) :: :ok
  def emit_dispatch(issue_identifier, class, priority) do
    :telemetry.execute(
      [:symphony_ex, :dispatch],
      %{system_time: System.system_time(:millisecond)},
      %{issue_identifier: issue_identifier, class: class, priority: priority}
    )
  end

  @doc """
  Emits `[:symphony_ex, :turn, :completed]` after a single agent turn.
  """
  @spec emit_turn_completed(String.t(), non_neg_integer() | nil, atom()) :: :ok
  def emit_turn_completed(issue_identifier, elapsed_ms, status) do
    :telemetry.execute(
      [:symphony_ex, :turn, :completed],
      %{elapsed_ms: elapsed_ms || 0, system_time: System.system_time(:millisecond)},
      %{issue_identifier: issue_identifier, status: status}
    )
  end

  @doc """
  Emits `[:symphony_ex, :write_back]` when a run record is persisted to the tracker.
  """
  @spec emit_write_back(String.t(), atom()) :: :ok
  def emit_write_back(issue_identifier, tracker_kind) do
    :telemetry.execute(
      [:symphony_ex, :write_back],
      %{system_time: System.system_time(:millisecond)},
      %{issue_identifier: issue_identifier, tracker_kind: tracker_kind}
    )
  end

  @doc """
  Emits `[:symphony_ex, :write_back, :stage]` for stage-level tracker sync visibility.
  """
  @spec emit_write_back_stage(String.t(), atom(), atom(), atom(), map()) :: :ok
  def emit_write_back_stage(issue_identifier, tracker_kind, stage, outcome, metadata \\ %{}) do
    :telemetry.execute(
      [:symphony_ex, :write_back, :stage],
      %{system_time: System.system_time(:millisecond)},
      Map.merge(metadata, %{
        issue_identifier: issue_identifier,
        tracker_kind: tracker_kind,
        stage: stage,
        outcome: outcome
      })
    )
  end

  @doc """
  Emits `[:symphony_ex, :rate_limit]` when tracker APIs report rate-limit state.
  """
  @spec emit_rate_limit(
          atom(),
          integer() | nil,
          integer() | nil,
          String.t() | nil,
          integer() | nil
        ) :: :ok
  def emit_rate_limit(source, remaining, limit, reset_at, retry_after \\ nil) do
    :telemetry.execute(
      [:symphony_ex, :rate_limit],
      %{system_time: System.system_time(:millisecond)},
      %{
        source: source,
        remaining: remaining,
        limit: limit,
        reset_at: reset_at,
        retry_after: retry_after
      }
    )
  end

  @doc """
  Emits `[:symphony_ex, :run, :finished]` when an agent run completes.
  """
  @spec emit_run_finished(String.t(), atom(), non_neg_integer() | nil) :: :ok
  def emit_run_finished(issue_identifier, result, elapsed_ms) do
    :telemetry.execute(
      [:symphony_ex, :run, :finished],
      %{elapsed_ms: elapsed_ms || 0, system_time: System.system_time(:millisecond)},
      %{issue_identifier: issue_identifier, result: result}
    )
  end
end
