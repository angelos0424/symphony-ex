defmodule SymphonyExWeb.DashboardAuth do
  @moduledoc """
  Shared authentication boundary for dashboard browser, API, and LiveView access.

  Authentication is configured at runtime so credentials never become module
  attributes or compile-time configuration. Only a boolean session marker is
  carried into LiveView connections; the password is never stored in session.
  """

  import Plug.Conn

  @realm "Symphony Dashboard"
  @session_key "dashboard_authenticated"

  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    if auth_required?() and not session_authenticated?(conn) do
      authenticate(conn)
    else
      conn
    end
  end

  @doc false
  @spec on_mount(:ensure_authenticated, map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    if not auth_required?() or Map.get(session, @session_key) == true do
      {:cont, socket}
    else
      {:halt,
       Phoenix.LiveView.put_flash(
         socket,
         :error,
         "Dashboard authentication is required."
       )}
    end
  end

  @spec auth_required?() :: boolean()
  def auth_required? do
    dashboard = dashboard_config()
    enabled = Keyword.get(dashboard, :enabled, false)

    enabled and not is_nil(credentials(dashboard))
  end

  @spec authenticate(Plug.Conn.t()) :: Plug.Conn.t()
  defp authenticate(conn) do
    {username, password} = credentials!(dashboard_config())

    conn
    |> Plug.BasicAuth.basic_auth(username: username, password: password, realm: @realm)
    |> maybe_mark_session_authenticated()
  end

  @spec maybe_mark_session_authenticated(Plug.Conn.t()) :: Plug.Conn.t()
  defp maybe_mark_session_authenticated(%Plug.Conn{halted: true} = conn), do: conn

  defp maybe_mark_session_authenticated(conn) do
    if session_fetched?(conn) do
      put_session(conn, @session_key, true)
    else
      conn
    end
  end

  @spec session_authenticated?(Plug.Conn.t()) :: boolean()
  defp session_authenticated?(conn) do
    session_fetched?(conn) and get_session(conn, @session_key) == true
  end

  @spec session_fetched?(Plug.Conn.t()) :: boolean()
  defp session_fetched?(conn), do: Map.has_key?(conn.private, :plug_session)

  @spec credentials(keyword()) :: {String.t(), String.t()} | nil
  defp credentials(dashboard) do
    auth = Keyword.get(dashboard, :auth, [])
    username = Keyword.get(auth, :username)
    password = Keyword.get(auth, :password)

    if is_binary(username) and username != "" and is_binary(password) and password != "" do
      {username, password}
    else
      nil
    end
  end

  @spec credentials!(keyword()) :: {String.t(), String.t()}
  defp credentials!(dashboard) do
    case credentials(dashboard) do
      {username, password} -> {username, password}
      nil -> raise ArgumentError, "dashboard basic authentication is not configured"
    end
  end

  @spec dashboard_config() :: keyword()
  defp dashboard_config do
    case Application.get_env(:symphony_ex, :dashboard_config, []) do
      config when is_list(config) -> config
      _other -> []
    end
  end
end
