defmodule SymphonyEx.RuntimeControl do
  @moduledoc """
  Bounded runtime control surface for dashboard-triggered apply/reload/restart actions.
  """

  alias SymphonyEx.{WorkflowEditor, WorkflowStore}

  @supervisor SymphonyEx.Supervisor

  @type component :: :orchestrator | :endpoint

  @spec apply_orchestrator_settings(map(), keyword()) ::
          {:ok, %{workflow_path: String.t(), settings: map()}} | {:error, term()}
  def apply_orchestrator_settings(params, opts \\ []) when is_map(params) do
    with {:ok, workflow_path} <- workflow_path(opts),
         {:ok, settings} <- normalize_orchestrator_settings(params),
         {:ok, _path} <- WorkflowEditor.update_orchestrator_settings(workflow_path, settings),
         {:ok, _config} <- reconfigure_runtime(workflow_path),
         :ok <- reload_workflow_store(opts),
         :ok <- refresh_orchestrator(opts) do
      {:ok, %{workflow_path: workflow_path, settings: settings}}
    end
  end

  @spec restart_component(component(), keyword()) :: {:ok, component()} | {:error, term()}
  def restart_component(component, opts \\ []) when component in [:orchestrator, :endpoint] do
    with {:ok, workflow_path} <- workflow_path(opts),
         {:ok, _config} <- reconfigure_runtime(workflow_path),
         :ok <- maybe_reload_workflow_store(component, opts),
         :ok <- restart_child(component, Keyword.get(opts, :supervisor, @supervisor)) do
      {:ok, component}
    end
  end

  @spec workflow_path(keyword()) :: {:ok, String.t()} | {:error, term()}
  def workflow_path(opts \\ []) do
    cond do
      path = Keyword.get(opts, :workflow_path) ->
        {:ok, path}

      Process.whereis(Keyword.get(opts, :workflow_store, WorkflowStore)) ->
        {:ok,
         WorkflowStore.snapshot(Keyword.get(opts, :workflow_store, WorkflowStore)).workflow_path}

      orchestrator_opts = Application.get_env(:symphony_ex, SymphonyEx.Orchestrator, []) ->
        case Keyword.get(orchestrator_opts, :workflow_path) do
          nil -> {:error, :workflow_path_unavailable}
          path -> {:ok, path}
        end

      path = SymphonyEx.workflow_path_from_env() ->
        {:ok, path}

      true ->
        {:error, :workflow_path_unavailable}
    end
  end

  @spec normalize_orchestrator_settings(map()) :: {:ok, map()} | {:error, term()}
  defp normalize_orchestrator_settings(params) do
    with {:ok, poll_interval_ms} <-
           parse_integer(params["poll_interval_ms"], :poll_interval_ms, min: 1),
         {:ok, max_concurrent} <-
           parse_integer(params["max_concurrent"], :max_concurrent, min: 1),
         {:ok, max_retries} <- parse_integer(params["max_retries"], :max_retries, min: 0),
         {:ok, backoff_base_ms} <-
           parse_integer(params["backoff_base_ms"], :backoff_base_ms, min: 1) do
      {:ok,
       %{
         poll_interval_ms: poll_interval_ms,
         max_concurrent: max_concurrent,
         max_retries: max_retries,
         backoff_base_ms: backoff_base_ms
       }}
    end
  end

  @spec parse_integer(term(), atom(), keyword()) :: {:ok, integer()} | {:error, term()}
  defp parse_integer(value, field, opts) do
    min = Keyword.get(opts, :min, 0)

    case Integer.parse(to_string(value || "")) do
      {parsed, ""} when parsed >= min -> {:ok, parsed}
      _other -> {:error, {:invalid_setting, field, min}}
    end
  end

  @spec reconfigure_runtime(String.t()) :: {:ok, keyword()} | {:error, term()}
  defp reconfigure_runtime(workflow_path) do
    {:ok, SymphonyEx.configure_from_workflow!(workflow_path)}
  rescue
    error in [ArgumentError, RuntimeError] -> {:error, error}
  end

  @spec reload_workflow_store(keyword()) :: :ok | {:error, term()}
  defp reload_workflow_store(opts) do
    store = Keyword.get(opts, :workflow_store, WorkflowStore)

    if Process.whereis(store) do
      case WorkflowStore.reload(store) do
        {:ok, _snapshot} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  @spec maybe_reload_workflow_store(component(), keyword()) :: :ok | {:error, term()}
  defp maybe_reload_workflow_store(:orchestrator, opts), do: reload_workflow_store(opts)
  defp maybe_reload_workflow_store(:endpoint, _opts), do: :ok

  @spec refresh_orchestrator(keyword()) :: :ok
  defp refresh_orchestrator(opts) do
    orchestrator = Keyword.get(opts, :orchestrator, SymphonyEx.Orchestrator)
    send(orchestrator, :tick)
    :ok
  end

  @spec restart_child(component(), Supervisor.supervisor()) :: :ok | {:error, term()}
  defp restart_child(component, supervisor) do
    child_id =
      case component do
        :orchestrator -> SymphonyEx.Orchestrator
        :endpoint -> SymphonyExWeb.Endpoint
      end

    with true <-
           child_present?(supervisor, child_id) || {:error, {:component_not_running, component}},
         :ok <- terminate_child(supervisor, child_id),
         :ok <- do_restart_child(supervisor, child_id) do
      :ok
    end
  end

  @spec child_present?(Supervisor.supervisor(), term()) :: boolean()
  defp child_present?(supervisor, child_id) do
    Enum.any?(Supervisor.which_children(supervisor), fn {id, _pid, _type, _modules} ->
      id == child_id
    end)
  end

  @spec terminate_child(Supervisor.supervisor(), term()) :: :ok | {:error, term()}
  defp terminate_child(supervisor, child_id) do
    case Supervisor.terminate_child(supervisor, child_id) do
      :ok -> :ok
      {:error, :not_found} -> :ok
      {:error, :not_allowed} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec do_restart_child(Supervisor.supervisor(), term()) :: :ok | {:error, term()}
  defp do_restart_child(supervisor, child_id) do
    case Supervisor.restart_child(supervisor, child_id) do
      {:ok, _pid} -> :ok
      {:ok, _pid, _extra} -> :ok
      {:error, :running} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
