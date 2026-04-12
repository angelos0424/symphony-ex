defmodule SymphonyEx.Dashboard do
  @moduledoc """
  Small PubSub bridge for dashboard consumers.

  The orchestrator owns runtime state; this module only exposes a stable topic so
  LiveView pages can subscribe without coupling themselves to GenServer internals.
  """

  @topic "dashboard:runtime"

  @type snapshot_message :: {:runtime_snapshot_updated, SymphonyEx.RuntimeSnapshot.snapshot()}

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec broadcast_snapshot(SymphonyEx.RuntimeSnapshot.snapshot()) :: :ok
  def broadcast_snapshot(snapshot) do
    case Process.whereis(SymphonyEx.PubSub) do
      nil ->
        :ok

      _pid ->
        Phoenix.PubSub.broadcast(SymphonyEx.PubSub, @topic, {:runtime_snapshot_updated, snapshot})
    end
  end
end
