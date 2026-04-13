defmodule SymphonyEx do
  @moduledoc """
  Runtime bootstrap helpers for SymphonyEx.

  The project still runs as an OTP application, but these helpers provide the
  missing bridge from a WORKFLOW.md file + environment variables into concrete
  runtime options for the orchestrator.
  """

  alias SymphonyEx.{Config, GitHub, Logging, Orchestrator, WorkflowStore}
  alias SymphonyEx.Orchestrator.Lifecycle

  @workflow_env_vars ["SYMPHONY_WORKFLOW_PATH", "WORKFLOW_PATH"]

  @type runtime_config :: keyword()

  @doc """
  Loads and validates runtime configuration from the given workflow file.
  """
  @spec load_runtime_config!(String.t()) :: runtime_config()
  def load_runtime_config!(workflow_path), do: Config.load!(workflow_path)

  @doc """
  Builds orchestrator startup options from a workflow file.
  """
  @spec orchestrator_opts_from_workflow!(String.t()) :: keyword()
  def orchestrator_opts_from_workflow!(workflow_path) do
    workflow_path
    |> load_runtime_config!()
    |> orchestrator_opts_from_config(workflow_path)
  end

  @doc """
  Builds orchestrator startup options from already-loaded config.
  """
  @spec orchestrator_opts_from_config(runtime_config(), String.t()) :: keyword()
  def orchestrator_opts_from_config(config, workflow_path) do
    tracker_opts =
      config
      |> Keyword.fetch!(:tracker)
      |> normalize_tracker_runtime_opts()

    workspace_opts = Keyword.fetch!(config, :workspace)
    codex_opts = Keyword.get(config, :codex, [])
    orchestrator_opts = Keyword.get(config, :orchestrator, [])

    [
      tracker: tracker_module(Keyword.get(tracker_opts, :kind, :github)),
      tracker_opts: tracker_opts,
      workspace_opts: workspace_opts,
      workflow_path: workflow_path,
      codex: codex_opts,
      issue_identifier: Keyword.get(orchestrator_opts, :issue_identifier),
      poll_interval_ms: Keyword.get(orchestrator_opts, :poll_interval_ms),
      max_concurrent: Keyword.get(orchestrator_opts, :max_concurrent),
      max_retries: Keyword.get(orchestrator_opts, :max_retries),
      retry_backoff_ms: Keyword.get(orchestrator_opts, :backoff_base_ms)
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @doc """
  Loads workflow config and stores orchestrator/workflow-store startup options
  in application env so `SymphonyEx.Application` can boot runtime services
  automatically.
  """
  @spec configure_from_workflow!(String.t()) :: keyword()
  def configure_from_workflow!(workflow_path) do
    config = load_runtime_config!(workflow_path)
    opts = orchestrator_opts_from_config(config, workflow_path)

    Application.put_env(:symphony_ex, :runtime_config, config)
    Application.put_env(:symphony_ex, Orchestrator, opts)
    Application.put_env(:symphony_ex, WorkflowStore, workflow_store_opts(workflow_path))
    :ok = Logging.configure_logger(Keyword.get(config, :logging, []))
    configure_dashboard(Keyword.get(config, :dashboard, []))
    opts
  end

  @doc """
  Returns the workflow path declared via environment variables, if any.
  """
  @spec workflow_path_from_env() :: String.t() | nil
  def workflow_path_from_env do
    Enum.find_value(@workflow_env_vars, &present_env/1)
  end

  @doc """
  Ensures orchestrator application env is populated from the runtime workflow
  path when it has not been configured explicitly.
  """
  @spec ensure_runtime_configured() :: keyword() | nil
  def ensure_runtime_configured do
    case Application.get_env(:symphony_ex, Orchestrator) do
      opts when is_list(opts) and opts != [] -> opts
      _other -> maybe_configure_from_env()
    end
  end

  @spec maybe_configure_from_env() :: keyword() | nil
  defp maybe_configure_from_env do
    case workflow_path_from_env() do
      nil -> nil
      workflow_path -> configure_from_workflow!(workflow_path)
    end
  end

  @spec configure_dashboard(keyword()) :: :ok
  defp configure_dashboard(dashboard_opts) do
    if Keyword.get(dashboard_opts, :enabled, false) do
      host = Keyword.get(dashboard_opts, :host, "127.0.0.1")
      port = Keyword.get(dashboard_opts, :port, 4000)

      endpoint_opts =
        [
          http: [ip: ip_tuple(host), port: port],
          url: [host: host, port: port],
          server: true,
          pubsub_server: SymphonyEx.PubSub
        ]
        |> maybe_put_secret_key_base(Keyword.get(dashboard_opts, :secret_key_base))

      Application.put_env(:symphony_ex, SymphonyExWeb.Endpoint, endpoint_opts)
    else
      Application.put_env(:symphony_ex, SymphonyExWeb.Endpoint, false)
    end

    :ok
  end

  @spec maybe_put_secret_key_base(keyword(), String.t() | nil) :: keyword()
  defp maybe_put_secret_key_base(opts, nil), do: opts
  defp maybe_put_secret_key_base(opts, secret), do: Keyword.put(opts, :secret_key_base, secret)

  @spec ip_tuple(String.t()) :: :inet.ip_address()
  defp ip_tuple(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      {:error, _} -> {127, 0, 0, 1}
    end
  end

  @spec workflow_store_opts(String.t()) :: keyword()
  def workflow_store_opts(workflow_path), do: [workflow_path: workflow_path]

  @spec normalize_tracker_runtime_opts(keyword()) :: keyword()
  defp normalize_tracker_runtime_opts(tracker_opts) do
    case Keyword.get(tracker_opts, :lifecycle) do
      %Lifecycle{} ->
        tracker_opts

      lifecycle_opts when is_list(lifecycle_opts) ->
        Keyword.put(tracker_opts, :lifecycle, Config.lifecycle_from_config(lifecycle_opts))

      _other ->
        tracker_opts
    end
  end

  @spec tracker_module(atom()) :: module()
  defp tracker_module(:github), do: GitHub.Adapter
  defp tracker_module(_other), do: GitHub.Adapter

  @spec present_env(String.t()) :: String.t() | nil
  defp present_env(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> value
    end
  end
end
