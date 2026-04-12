defmodule SymphonyExWeb.ApiController do
  @moduledoc """
  Minimal JSON visibility API for the orchestration runtime.

  This is the first bounded dashboard slice: a stable machine-readable surface
  for status pages, CLI inspection, and future LiveView wiring.
  """

  use SymphonyExWeb, :controller

  alias SymphonyEx.RuntimeSnapshot

  @spec status(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def status(conn, _params) do
    snapshot = RuntimeSnapshot.from_orchestrator(orchestrator_server())

    json(conn, %{
      summary: snapshot.summary,
      settings: snapshot.settings,
      running_count: snapshot.summary.running_count,
      retry_queue_count: snapshot.summary.retry_queue_count
    })
  end

  @spec issues(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def issues(conn, _params) do
    snapshot = RuntimeSnapshot.from_orchestrator(orchestrator_server())

    json(conn, %{
      running: snapshot.running,
      retry_queue: snapshot.retry_queue,
      completed: snapshot.completed,
      completed_issue_identifiers: snapshot.completed_issue_identifiers
    })
  end

  @spec run(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def run(conn, %{"identifier" => identifier}) do
    snapshot = RuntimeSnapshot.from_orchestrator(orchestrator_server())

    case RuntimeSnapshot.run_detail(snapshot, identifier) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "run_not_found", identifier: identifier})

      run ->
        json(conn, run)
    end
  end

  @spec orchestrator_server() :: GenServer.server()
  defp orchestrator_server do
    Application.get_env(:symphony_ex, :dashboard_orchestrator, SymphonyEx.Orchestrator)
  end
end
