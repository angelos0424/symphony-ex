defmodule SymphonyExWeb.Router do
  @moduledoc false

  use SymphonyExWeb, :router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(SymphonyExWeb.DashboardAuth)
    plug(:put_root_layout, false)
  end

  pipeline :api do
    plug(:accepts, ["json"])
    plug(SymphonyExWeb.DashboardAuth)
  end

  scope "/", SymphonyExWeb do
    pipe_through(:browser)

    live("/", DashboardLive, :index)
    live("/runs/:identifier", DashboardLive, :show)
  end

  scope "/api/v1", SymphonyExWeb do
    pipe_through(:api)

    get("/status", ApiController, :status)
    get("/issues", ApiController, :issues)
    get("/runs/:identifier", ApiController, :run)
  end
end
