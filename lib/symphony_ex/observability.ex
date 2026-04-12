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

  @type state :: %{optional(atom()) => rate_limit_snapshot()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @spec snapshot() :: state()
  def snapshot do
    case Process.whereis(__MODULE__) do
      nil -> %{}
      _pid -> GenServer.call(__MODULE__, :snapshot)
    end
  end

  @spec record_rate_limit(atom(), map()) :: :ok
  def record_rate_limit(source, attrs) when is_atom(source) and is_map(attrs) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:record_rate_limit, source, attrs})
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:record_rate_limit, source, attrs}, state) do
    {:noreply, Map.put(state, source, normalize_rate_limit(attrs))}
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
end
