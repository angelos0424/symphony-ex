defmodule SymphonyEx.WorkflowStore do
  @moduledoc """
  Keeps the current WORKFLOW.md runtime config/template in memory and reloads it
  when the file changes.

  The store is intentionally bounded: it watches a single workflow file, exposes
  the latest validated config + template body, and lets runtime components pull
  fresh values without forcing an app restart.
  """

  use GenServer
  require Logger

  alias SymphonyEx.Config

  @type snapshot :: %{
          workflow_path: String.t(),
          config: keyword(),
          template: String.t(),
          content_hash: binary(),
          loaded_at: DateTime.t(),
          reload_count: non_neg_integer()
        }

  @type state :: %{
          workflow_path: String.t(),
          watcher: pid() | nil,
          config: keyword(),
          template: String.t(),
          content_hash: binary(),
          loaded_at: DateTime.t(),
          reload_count: non_neg_integer()
        }

  @default_name __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, @default_name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec get_config(GenServer.server()) :: keyword() | nil
  def get_config(server \\ @default_name), do: GenServer.call(server, :get_config)

  @spec get_template(GenServer.server()) :: String.t() | nil
  def get_template(server \\ @default_name), do: GenServer.call(server, :get_template)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ @default_name), do: GenServer.call(server, :snapshot)

  @spec reload(GenServer.server()) :: {:ok, snapshot()} | {:error, term()}
  def reload(server \\ @default_name), do: GenServer.call(server, :reload)

  @impl true
  def init(opts) do
    workflow_path = Keyword.fetch!(opts, :workflow_path)
    watcher? = Keyword.get(opts, :watcher, true)

    state =
      workflow_path
      |> load_snapshot!(0)
      |> Map.put(:watcher, nil)

    state = if watcher?, do: maybe_start_watcher(state), else: state
    {:ok, state}
  end

  @impl true
  def handle_call(:get_config, _from, state), do: {:reply, state.config, state}

  def handle_call(:get_template, _from, state), do: {:reply, state.template, state}

  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from_state(state), state}

  def handle_call(:reload, _from, state) do
    case reload_state(state, :manual) do
      {:ok, next_state} -> {:reply, {:ok, snapshot_from_state(next_state)}, next_state}
      {:error, reason, next_state} -> {:reply, {:error, reason}, next_state}
    end
  end

  @impl true
  def handle_info({:file_event, watcher, {path, events}}, %{watcher: watcher} = state) do
    if workflow_event?(state.workflow_path, path, events) do
      case reload_state(state, {:file_event, events}) do
        {:ok, next_state} -> {:noreply, next_state}
        {:error, _reason, next_state} -> {:noreply, next_state}
      end
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, _watcher, _event}, state), do: {:noreply, state}

  def handle_info({:file_error, watcher, reason}, %{watcher: watcher} = state) do
    Logger.warning("workflow watcher error",
      workflow_path: state.workflow_path,
      watcher_error: inspect(reason)
    )

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec maybe_start_watcher(state()) :: state()
  defp maybe_start_watcher(state) do
    watcher_module = watcher_module()

    with {:module, _} <- Code.ensure_loaded(watcher_module),
         {:ok, watcher} <- watcher_module.start_link(dirs: [Path.dirname(state.workflow_path)]),
         :ok <- watcher_module.subscribe(watcher),
         :ok <- watcher_module.start(watcher) do
      %{state | watcher: watcher}
    else
      error ->
        Logger.warning("workflow watcher unavailable",
          workflow_path: state.workflow_path,
          watcher_error: inspect(error)
        )

        state
    end
  end

  @spec reload_state(state(), term()) :: {:ok, state()} | {:error, term(), state()}
  defp reload_state(state, source) do
    case load_snapshot(state.workflow_path, state.reload_count + 1) do
      {:ok, loaded} ->
        next_state =
          loaded
          |> Map.put(:watcher, state.watcher)
          |> maybe_log_reload(state, source)

        maybe_configure_logger(next_state.config)
        {:ok, next_state}

      {:error, reason} ->
        Logger.warning("workflow reload failed",
          workflow_path: state.workflow_path,
          reload_source: inspect(source),
          error: inspect(reason)
        )

        {:error, reason, state}
    end
  end

  @spec maybe_log_reload(state(), state(), term()) :: state()
  defp maybe_log_reload(next_state, prev_state, source) do
    if next_state.content_hash != prev_state.content_hash do
      Logger.info("workflow reloaded",
        workflow_path: next_state.workflow_path,
        reload_source: inspect(source),
        reload_count: next_state.reload_count
      )
    end

    next_state
  end

  @spec load_snapshot!(String.t(), non_neg_integer()) :: map()
  defp load_snapshot!(workflow_path, reload_count) do
    case load_snapshot(workflow_path, reload_count) do
      {:ok, snapshot} -> snapshot
      {:error, reason} -> raise "failed to load workflow #{workflow_path}: #{inspect(reason)}"
    end
  end

  @spec load_snapshot(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, term()}
  defp load_snapshot(workflow_path, reload_count) do
    with {:ok, content} <- File.read(workflow_path),
         {:ok, config} <- Config.load(workflow_path) do
      template = extract_template(content)

      {:ok,
       %{
         workflow_path: workflow_path,
         config: config,
         template: template,
         content_hash: :crypto.hash(:sha256, content),
         loaded_at: DateTime.utc_now(),
         reload_count: reload_count
       }}
    end
  end

  @spec extract_template(String.t()) :: String.t()
  defp extract_template(content) do
    case Regex.run(~r/\A---\n.*?\n---\n?(.*)/s, content) do
      [_, body] -> body
      nil -> content
    end
  end

  @spec snapshot_from_state(state()) :: snapshot()
  defp snapshot_from_state(state) do
    Map.take(state, [:workflow_path, :config, :template, :content_hash, :loaded_at, :reload_count])
  end

  @spec workflow_event?(String.t(), String.t() | [String.t()], [atom()]) :: boolean()
  defp workflow_event?(workflow_path, paths, events) when is_list(paths) do
    Enum.any?(paths, &workflow_event?(workflow_path, &1, events))
  end

  defp workflow_event?(workflow_path, path, events) do
    expanded_workflow = Path.expand(workflow_path)
    expanded_path = Path.expand(to_string(path))
    relevant? = Enum.any?(events, &(&1 in [:modified, :closed, :created, :moved_to]))
    relevant? and expanded_workflow == expanded_path
  end

  defp watcher_module, do: Application.get_env(:symphony_ex, :workflow_watcher_module, FileSystem)

  defp maybe_configure_logger(config) do
    logging_opts = Keyword.get(config, :logging, [])
    _ = SymphonyEx.Logging.configure_logger(logging_opts)
    :ok
  end
end
