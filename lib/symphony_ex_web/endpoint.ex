defmodule SymphonyExWeb.Endpoint do
  @moduledoc """
  Optional Bandit/Phoenix endpoint for runtime visibility APIs.
  """

  use SymphonyExWeb, :endpoint

  @session_options [store: :cookie, key: "_symphony_ex_key", signing_salt: "dashboard-salt"]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:symphony_ex, :endpoint])
  plug(Plug.Session, @session_options)
  plug(SymphonyExWeb.Router)
end
