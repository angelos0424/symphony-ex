defmodule SymphonyEx.Application do
  @moduledoc """
  OTP Application for Symphony.
  Starts the supervision tree with the shared task supervisor and, when enabled,
  the orchestrator itself.
  """

  use Application

  @impl true
  def start(_type, _args) do
    SymphonyEx.ensure_runtime_configured()

    children =
      [
        {Task.Supervisor, name: SymphonyEx.AgentWorkers}
      ] ++
        observability_children() ++
        pubsub_children() ++
        workflow_store_children() ++
        single_active_guard_children() ++
        orchestrator_children() ++
        endpoint_children()

    opts = [strategy: :one_for_one, name: SymphonyEx.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @spec observability_children() :: [Supervisor.child_spec()]
  defp observability_children, do: [SymphonyEx.Observability]

  @spec pubsub_children() :: [Supervisor.child_spec()]
  defp pubsub_children do
    case Application.get_env(:symphony_ex, SymphonyExWeb.Endpoint, nil) do
      false -> []
      nil -> []
      _opts -> [{Phoenix.PubSub, name: SymphonyEx.PubSub}]
    end
  end

  @spec workflow_store_children() :: [Supervisor.child_spec()]
  defp workflow_store_children do
    case Application.get_env(:symphony_ex, SymphonyEx.WorkflowStore, nil) do
      opts when is_list(opts) and opts != [] ->
        [{SymphonyEx.WorkflowStore, opts}]

      _other ->
        []
    end
  end

  @spec orchestrator_children() :: [Supervisor.child_spec()]
  defp orchestrator_children do
    case Application.get_env(:symphony_ex, SymphonyEx.Orchestrator, nil) do
      false ->
        []

      nil ->
        []

      [] ->
        []

      opts when is_list(opts) ->
        [
          {SymphonyEx.Orchestrator,
           Keyword.put_new(opts, :task_supervisor, SymphonyEx.AgentWorkers)}
        ]
    end
  end

  @spec single_active_guard_children() :: [Supervisor.child_spec()]
  defp single_active_guard_children do
    case Application.get_env(:symphony_ex, SymphonyEx.Orchestrator, nil) do
      opts when is_list(opts) and opts != [] ->
        workflow_path = Keyword.get(opts, :workflow_path)
        lock_path = Keyword.get(opts, :single_active_lock_path)

        if workflow_path || lock_path do
          [
            {SymphonyEx.SingleActiveGuard,
             [
               workflow_path: workflow_path,
               lock_path: lock_path,
               name: SymphonyEx.SingleActiveGuard
             ]}
          ]
        else
          []
        end

      _other ->
        []
    end
  end

  @spec endpoint_children() :: [Supervisor.child_spec()]
  defp endpoint_children do
    case Application.get_env(:symphony_ex, SymphonyExWeb.Endpoint, nil) do
      false ->
        []

      nil ->
        []

      opts when is_list(opts) ->
        [{SymphonyExWeb.Endpoint, opts}]
    end
  end
end
