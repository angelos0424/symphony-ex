defmodule SymphonyEx.Codex.AppServer do
  @moduledoc """
  GenServer managing the Codex app-server process.
  Communicates via JSON-RPC over stdio (line-delimited).
  """
  use GenServer
  require Logger

  alias SymphonyEx.Codex.{EventParser, JsonRpc}
  alias SymphonyEx.Domain.Events
  alias SymphonyEx.Logging

  @type state :: %{
          port: port() | nil,
          request_id: pos_integer(),
          pending: %{pos_integer() => {pid(), reference()}},
          events: [Events.t()],
          subscribers: [pid()],
          command: String.t(),
          cwd: String.t(),
          capabilities: map(),
          status: :idle | :initializing | :running | :stopped
        }

  @method_fallbacks %{
    "initialize" => ["session/initialize"],
    "thread/start" => ["thread/create", "session/start"],
    "turn/start" => ["turn/create", "session/turn"],
    "turn/cancel" => ["turn/interrupt", "turn/abort", "turn/stop"],
    "shutdown" => ["session/end", "session/close"],
    "approval/deny" => ["approval/respond", "approval/reject"]
  }

  # --- Client API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec initialize(GenServer.server()) :: {:ok, map()} | {:error, term()}
  def initialize(server) do
    GenServer.call(server, :initialize, 30_000)
  end

  @spec start_thread(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def start_thread(server, params \\ %{}) do
    GenServer.call(server, {:rpc, "thread/start", params}, 30_000)
  end

  @spec start_turn(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def start_turn(server, params) do
    GenServer.call(server, {:rpc, "turn/start", params}, 30_000)
  end

  @spec cancel_turn(GenServer.server()) :: :ok
  def cancel_turn(server) do
    GenServer.cast(server, :cancel_turn)
  end

  @spec shutdown(GenServer.server()) :: :ok
  def shutdown(server) do
    GenServer.call(server, :shutdown, 10_000)
  catch
    :exit, _ -> :ok
  end

  @spec subscribe(GenServer.server(), pid()) :: :ok
  def subscribe(server, pid \\ self()) do
    GenServer.cast(server, {:subscribe, pid})
  end

  @spec get_events(GenServer.server()) :: [Events.t()]
  def get_events(server) do
    GenServer.call(server, :get_events)
  end

  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    GenServer.call(server, :alive?)
  catch
    :exit, _ -> false
  end

  @spec capabilities(GenServer.server()) :: map()
  def capabilities(server) do
    GenServer.call(server, :capabilities)
  catch
    :exit, _ -> %{}
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    command = Keyword.fetch!(opts, :command)
    cwd = Keyword.fetch!(opts, :cwd)

    state = %{
      port: nil,
      request_id: 1,
      pending: %{},
      events: [],
      subscribers: [],
      command: command,
      cwd: cwd,
      capabilities: %{},
      status: :idle
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:initialize, from, %{status: :idle} = state) do
    port = spawn_codex(state.command, state.cwd)

    state = %{state | port: port, status: :initializing}
    send_rpc(state, "initialize", initialize_params(), from)
  end

  def handle_call({:rpc, method, params}, from, state) do
    send_rpc(state, method, params, from)
  end

  def handle_call(:shutdown, from, state) do
    {state, _id} = do_send_rpc(state, "shutdown", %{})
    GenServer.reply(from, :ok)
    cleanup(state)
    {:stop, :normal, state}
  end

  def handle_call(:get_events, _from, state) do
    {:reply, Enum.reverse(state.events), state}
  end

  def handle_call(:alive?, _from, state) do
    {:reply, state.port != nil and state.status in [:initializing, :running], state}
  end

  def handle_call(:capabilities, _from, state) do
    {:reply, state.capabilities, state}
  end

  @impl true
  def handle_cast(:cancel_turn, state) do
    {state, _id} = do_send_rpc(state, "turn/cancel", %{})
    {:noreply, state}
  end

  def handle_cast({:subscribe, pid}, state) do
    {:noreply, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state) do
    handle_stdout_line(line, state)
  end

  def handle_info({port, {:data, {:noeol, _chunk}}}, %{port: port} = state) do
    # Partial line — buffer if needed (simplified: ignore for now)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning(
      "codex process exited",
      exit_status: code,
      cwd: state.cwd,
      pending_request_count: map_size(state.pending),
      codex_status: state.status
    )

    # Reject all pending requests
    for {_id, {pid, _ref}} <- state.pending do
      send(pid, {:rpc_error, :process_exit})
    end

    {:noreply, %{state | port: nil, status: :stopped, pending: %{}}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # --- Private ---

  @spec spawn_codex(String.t(), String.t()) :: port()
  defp spawn_codex(command, cwd) do
    Port.open(
      {:spawn, "bash -lc '#{command}'"},
      [
        :binary,
        :exit_status,
        {:line, 10_485_760},
        {:cd, cwd},
        {:env, [{~c"TERM", ~c"dumb"}]}
      ]
    )
  end

  @spec send_rpc(state(), String.t(), map(), GenServer.from()) ::
          {:noreply, state()}
  defp send_rpc(state, method, params, from) do
    {state, id} = do_send_rpc(state, method, params)
    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | pending: pending}}
  end

  @spec do_send_rpc(state(), String.t(), map()) :: {state(), pos_integer()}
  defp do_send_rpc(state, method, params) do
    id = state.request_id
    line = JsonRpc.encode_request(id, method, params)
    send_to_port(state.port, line <> "\n")
    {%{state | request_id: id + 1}, id}
  end

  @spec send_to_port(port() | nil, String.t()) :: :ok
  defp send_to_port(nil, _data), do: :ok

  defp send_to_port(port, data) do
    Port.command(port, data)
    :ok
  end

  @spec send_notification(port() | nil, String.t(), map()) :: :ok
  defp send_notification(port, method, params) do
    send_to_port(port, JsonRpc.encode_notification(method, params) <> "\n")
  end

  @spec initialize_params() :: map()
  defp initialize_params do
    %{
      "clientInfo" => %{
        "name" => "symphony_ex",
        "title" => "SymphonyEx",
        "version" => Application.spec(:symphony_ex, :vsn) |> to_string()
      }
    }
  end

  @spec handle_stdout_line(String.t(), state()) :: {:noreply, state()}
  defp handle_stdout_line(line, state) do
    case JsonRpc.decode_line(line) do
      {:response, response} ->
        handle_response(response, state)

      {:notification, notification} ->
        event = EventParser.parse(notification)
        state = %{state | events: [event | state.events]}
        notify_subscribers(state.subscribers, event)

        # Handle control events (deny approvals, reject tool calls)
        state = maybe_handle_control_event(event, state)

        {:noreply, state}

      {:error, _reason} ->
        # Non-JSON line from stderr passthrough — ignore
        {:noreply, state}
    end
  end

  @spec handle_response(JsonRpc.response(), state()) :: {:noreply, state()}
  defp handle_response(%{id: id} = response, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {from, pending} ->
        state = %{state | pending: pending}

        reply =
          case response do
            %{error: %{} = error} when map_size(error) > 0 ->
              # Check if method unsupported — try fallback
              {:error, error}

            %{result: result} ->
              {:ok, result}
          end

        # On successful initialize, update capabilities and status
        updated_state =
          case reply do
            {:ok, result} when state.status == :initializing ->
              caps = extract_capabilities(result)
              updated_state = %{state | capabilities: caps, status: :running}
              send_notification(updated_state.port, "initialized", %{})
              updated_state

            _ ->
              state
          end

        GenServer.reply(from, reply)
        {:noreply, updated_state}
    end
  end

  @spec maybe_handle_control_event(Events.t(), state()) :: state()
  defp maybe_handle_control_event(%Events{event: :approval_requested} = event, state) do
    Logger.info(
      "denying approval request",
      Logging.logger_metadata(%{
        raw_method: event.raw_method,
        last_event: event.event,
        turn_id: get_in(event.params, ["turnId"]),
        thread_id: get_in(event.params, ["threadId"]),
        call_id: get_in(event.params, ["callId"])
      })
    )

    {state, _id} =
      do_send_rpc(state, "approval/deny", %{
        "decision" => "deny",
        "reason" => "Symphony runs in non-interactive mode"
      })

    state
  end

  defp maybe_handle_control_event(%Events{event: :tool_call_requested} = event, state) do
    Logger.info(
      "rejecting tool call request",
      Logging.logger_metadata(%{
        raw_method: event.raw_method,
        last_event: event.event,
        turn_id: get_in(event.params, ["turnId"]),
        thread_id: get_in(event.params, ["threadId"]),
        call_id: get_in(event.params, ["callId"]),
        tool_name: get_in(event.params, ["toolName"])
      })
    )

    state
  end

  defp maybe_handle_control_event(_event, state), do: state

  @spec notify_subscribers([pid()], Events.t()) :: :ok
  defp notify_subscribers(subscribers, event) do
    for pid <- subscribers, Process.alive?(pid) do
      send(pid, {:app_server_event, event})
    end

    :ok
  end

  @spec extract_capabilities(map() | nil) :: map()
  defp extract_capabilities(nil), do: %{}

  defp extract_capabilities(result) do
    %{
      supports_events: result["supportsEvents"] || false,
      supports_recovery: result["supportsRecovery"] || false,
      supports_thread_reuse: result["supportsThreadReuse"] || false,
      supports_approval_requests: result["supportsApprovalRequests"] || false,
      supports_tool_calls: result["supportsToolCalls"] || false,
      supports_status: result["supportsStatus"] || false
    }
  end

  @doc "Returns the method fallback chain for a given primary method."
  @spec fallbacks(String.t()) :: [String.t()]
  def fallbacks(method), do: Map.get(@method_fallbacks, method, [])

  @spec cleanup(state()) :: :ok
  defp cleanup(%{port: nil}), do: :ok

  defp cleanup(%{port: port}) do
    Port.close(port)
    :ok
  catch
    _, _ -> :ok
  end
end
