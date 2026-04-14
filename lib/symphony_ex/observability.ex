defmodule SymphonyEx.Observability do
  @moduledoc """
  Small in-memory store for dashboard-facing observability snapshots.

  Today this tracks the latest API rate-limit state seen from external tracker
  calls so the dashboard/API surface can expose it without scraping logs.
  """

  use GenServer

  @type rate_limit_snapshot :: %{
          optional(:remaining) => integer() | nil,
          optional(:limit) => integer() | nil,
          optional(:reset_at) => String.t() | nil,
          optional(:retry_after) => integer() | nil,
          optional(:captured_at) => String.t()
        }

  @type write_back_stage_event :: %{
          issue_identifier: String.t(),
          tracker_kind: String.t(),
          stage: String.t(),
          outcome: String.t(),
          failed_stage: String.t() | nil,
          status: String.t() | nil,
          reason: String.t() | nil,
          captured_at: String.t()
        }

  @type write_back_stage_snapshot :: %{
          recent: [write_back_stage_event()],
          alert_count: non_neg_integer()
        }

  @type state :: %{
          rate_limits: %{optional(atom()) => rate_limit_snapshot()},
          write_back_stages: %{
            recent: [write_back_stage_event()],
            by_issue: %{optional(String.t()) => [write_back_stage_event()]}
          }
        }

  @recent_write_back_limit 20
  @per_issue_write_back_limit 10

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, initial_state(), Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec snapshot() :: state()
  def snapshot do
    case Process.whereis(__MODULE__) do
      nil -> snapshot_from_state(initial_state())
      _pid -> GenServer.call(__MODULE__, :snapshot)
    end
  end

  @spec write_back_stage_events(String.t() | nil) :: [write_back_stage_event()]
  def write_back_stage_events(issue_identifier \\ nil) do
    case Process.whereis(__MODULE__) do
      nil ->
        []

      _pid ->
        GenServer.call(__MODULE__, {:write_back_stage_events, issue_identifier})
    end
  end

  @spec record_rate_limit(atom(), map()) :: :ok
  def record_rate_limit(source, attrs) when is_atom(source) and is_map(attrs) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:record_rate_limit, source, attrs})
    end
  end

  @spec record_write_back_stage(String.t(), atom(), atom(), atom(), map()) :: :ok
  def record_write_back_stage(issue_identifier, tracker_kind, stage, outcome, metadata \\ %{})
      when is_binary(issue_identifier) and is_atom(tracker_kind) and is_atom(stage) and
             is_atom(outcome) and is_map(metadata) do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      _pid ->
        GenServer.cast(
          __MODULE__,
          {:record_write_back_stage, issue_identifier, tracker_kind, stage, outcome, metadata}
        )
    end
  end

  @spec reset() :: :ok
  def reset do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :reset)
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from_state(state), state}

  def handle_call({:write_back_stage_events, nil}, _from, state) do
    {:reply, state.write_back_stages.recent, state}
  end

  def handle_call({:write_back_stage_events, issue_identifier}, _from, state) do
    {:reply, get_in(state, [:write_back_stages, :by_issue, issue_identifier]) || [], state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, initial_state()}

  @impl true
  def handle_cast({:record_rate_limit, source, attrs}, state) do
    {:noreply, put_in(state, [:rate_limits, source], normalize_rate_limit(attrs))}
  end

  def handle_cast(
        {:record_write_back_stage, issue_identifier, tracker_kind, stage, outcome, metadata},
        state
      ) do
    event = normalize_write_back_stage(issue_identifier, tracker_kind, stage, outcome, metadata)

    state =
      state
      |> update_in([:write_back_stages, :recent], fn recent ->
        [event | recent] |> Enum.take(@recent_write_back_limit)
      end)
      |> update_in([:write_back_stages, :by_issue, issue_identifier], fn events ->
        [event | List.wrap(events)] |> Enum.take(@per_issue_write_back_limit)
      end)

    {:noreply, state}
  end

  @spec initial_state() :: state()
  defp initial_state do
    %{
      rate_limits: %{},
      write_back_stages: %{recent: [], by_issue: %{}}
    }
  end

  @spec snapshot_from_state(state()) :: %{rate_limits: map(), write_back_stages: write_back_stage_snapshot()}
  defp snapshot_from_state(state) do
    recent = get_in(state, [:write_back_stages, :recent]) || []

    %{
      rate_limits: Map.get(state, :rate_limits, %{}),
      write_back_stages: %{
        recent: recent,
        alert_count: Enum.count(recent, &(&1.outcome != "success"))
      }
    }
  end

  defp normalize_rate_limit(attrs) do
    %{
      remaining: integer_or_nil(attrs[:remaining]),
      limit: integer_or_nil(attrs[:limit]),
      reset_at: reset_at(attrs[:reset]),
      retry_after: integer_or_nil(attrs[:retry_after]),
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp normalize_write_back_stage(issue_identifier, tracker_kind, stage, outcome, metadata) do
    %{
      issue_identifier: issue_identifier,
      tracker_kind: to_string(tracker_kind),
      stage: to_string(stage),
      outcome: to_string(outcome),
      failed_stage: normalize_stage_name(metadata[:failed_stage]),
      status: normalize_stage_name(metadata[:status]),
      reason: normalize_reason(metadata[:reason]),
      captured_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp integer_or_nil(nil), do: nil
  defp integer_or_nil(value) when is_integer(value), do: value

  defp integer_or_nil(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp integer_or_nil(_value), do: nil

  defp reset_at(nil), do: nil

  defp reset_at(value) when is_integer(value) do
    value
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp reset_at(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> reset_at(parsed)
      :error -> nil
    end
  end

  defp reset_at(_value), do: nil

  defp normalize_stage_name(nil), do: nil
  defp normalize_stage_name(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_stage_name(value), do: to_string(value)

  defp normalize_reason(nil), do: nil
  defp normalize_reason(value), do: to_string(value)
end
