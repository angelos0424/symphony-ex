defmodule SymphonyEx.SingleActiveGuard do
  @moduledoc """
  Host-local startup guard for the single active orchestrator deployment model.

  The current system explicitly supports one active orchestrator per project.
  This guard enforces that assumption at application boot by holding a
  workflow-scoped lock file for the lifetime of the process.
  """

  use GenServer

  @type state :: %{
          lock_path: String.t(),
          metadata: map()
        }

  @default_lock_subdir "symphony_ex/orchestrator-locks"

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name))
  end

  @impl true
  def init(opts) do
    with {:ok, lock_path} <- lock_path_from_opts(opts),
         metadata <- lock_metadata(opts),
         :ok <- acquire_lock(lock_path, metadata) do
      {:ok, %{lock_path: lock_path, metadata: metadata}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    release_lock(state)
    :ok
  end

  @spec default_lock_path!(String.t()) :: String.t()
  def default_lock_path!(workflow_path) do
    digest =
      :sha256
      |> :crypto.hash(Path.expand(workflow_path))
      |> Base.encode16(case: :lower)

    Path.join([System.tmp_dir!(), @default_lock_subdir, "#{digest}.lock"])
  end

  defp lock_path_from_opts(opts) do
    cond do
      lock_path = Keyword.get(opts, :lock_path) ->
        {:ok, lock_path}

      workflow_path = Keyword.get(opts, :workflow_path) ->
        {:ok, default_lock_path!(workflow_path)}

      true ->
        {:error, {:missing_lock_path, :workflow_path}}
    end
  end

  defp acquire_lock(lock_path, metadata, attempts \\ 0)

  defp acquire_lock(lock_path, metadata, attempts) when attempts < 2 do
    lock_path
    |> Path.dirname()
    |> File.mkdir_p!()
    |> case do
      :ok ->
        case File.write(lock_path, Jason.encode!(metadata), [:exclusive]) do
          :ok ->
            :ok

          {:error, :eexist} ->
            maybe_reclaim_stale_lock(lock_path, metadata, attempts)

          {:error, reason} ->
            {:error, {:single_active_guard_failed, lock_path, reason}}
        end
    end
  end

  defp acquire_lock(lock_path, _metadata, _attempts),
    do: {:error, {:single_active_guard_failed, lock_path, :stale_reclaim_exhausted}}

  defp maybe_reclaim_stale_lock(lock_path, metadata, attempts) do
    case read_lock_metadata(lock_path) do
      {:ok, existing} ->
        if stale_lock?(existing) do
          case File.rm(lock_path) do
            :ok -> acquire_lock(lock_path, metadata, attempts + 1)
            {:error, :enoent} -> acquire_lock(lock_path, metadata, attempts + 1)
            {:error, reason} -> {:error, {:single_active_guard_failed, lock_path, reason}}
          end
        else
          {:error, {:single_active_orchestrator, lock_path, existing}}
        end

      {:error, reason} ->
        {:error, {:single_active_guard_failed, lock_path, reason}}
    end
  end

  defp read_lock_metadata(lock_path) do
    with {:ok, body} <- File.read(lock_path),
         {:ok, metadata} <- Jason.decode(body) do
      {:ok, metadata}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_lock_metadata}
    end
  end

  defp stale_lock?(metadata) when is_map(metadata) do
    metadata["hostname"] == hostname() and
      is_integer(metadata["os_pid"]) and
      not os_process_alive?(metadata["os_pid"])
  end

  defp stale_lock?(_metadata), do: false

  defp os_process_alive?(pid) when is_integer(pid) and pid > 0 do
    case System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  rescue
    _error -> false
  end

  defp os_process_alive?(_pid), do: false

  defp release_lock(%{lock_path: lock_path, metadata: metadata}) do
    case read_lock_metadata(lock_path) do
      {:ok, existing} when existing == metadata ->
        File.rm(lock_path)
        :ok

      _other ->
        :ok
    end
  end

  defp release_lock(_state), do: :ok

  defp lock_metadata(opts) do
    %{
      "workflow_path" => maybe_expand_path(Keyword.get(opts, :workflow_path)),
      "hostname" => hostname(),
      "os_pid" => os_pid(),
      "node" => inspect(node()),
      "guard_pid" => inspect(self()),
      "started_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp maybe_expand_path(nil), do: nil
  defp maybe_expand_path(path), do: Path.expand(path)

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _other -> System.get_env("HOSTNAME") || "unknown-host"
    end
  end

  defp os_pid do
    System.pid()
    |> String.to_integer()
  rescue
    _error -> -1
  end
end
