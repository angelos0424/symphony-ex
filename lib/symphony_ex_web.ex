defmodule SymphonyExWeb do
  @moduledoc """
  Phoenix entrypoint for dashboard/API web modules.
  """

  def controller do
    quote do
      use Phoenix.Controller, formats: [:json]
      import Plug.Conn
      unquote(verified_routes())
    end
  end

  def router do
    quote do
      use Phoenix.Router
      import Plug.Conn
      import Phoenix.Controller
      import Phoenix.LiveView.Router
    end
  end

  def endpoint do
    quote do
      use Phoenix.Endpoint, otp_app: :symphony_ex
    end
  end

  def live_view do
    quote do
      use Phoenix.LiveView
      unquote(html())
    end
  end

  def html do
    quote do
      use Phoenix.Component
      import Phoenix.HTML
      unquote(verified_routes())
    end
  end

  def verified_routes do
    quote do
      use Phoenix.VerifiedRoutes,
        endpoint: SymphonyExWeb.Endpoint,
        router: SymphonyExWeb.Router,
        statics: []
    end
  end

  @spec __using__(atom()) :: Macro.t()
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
