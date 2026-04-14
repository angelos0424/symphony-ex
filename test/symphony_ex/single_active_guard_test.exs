defmodule SymphonyEx.SingleActiveGuardTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.SingleActiveGuard

  test "acquires and releases a workflow-scoped lock" do
    lock_path = temp_lock_path("single-active")

    guard = start_temporary_guard!(lock_path: lock_path)

    assert File.exists?(lock_path)

    GenServer.stop(guard, :shutdown)

    wait_until(fn -> not File.exists?(lock_path) end)
  end

  test "rejects a second live guard for the same project lock" do
    lock_path = temp_lock_path("single-active-conflict")

    _guard = start_temporary_guard!(lock_path: lock_path)

    assert {:error, {:single_active_orchestrator, ^lock_path, existing}} =
             SingleActiveGuard.start_link(lock_path: lock_path)

    assert existing["os_pid"] == String.to_integer(System.pid())
  end

  test "reclaims a stale lock from a dead host-local process" do
    lock_path = temp_lock_path("single-active-stale")
    File.mkdir_p!(Path.dirname(lock_path))

    File.write!(
      lock_path,
      Jason.encode!(%{
        "workflow_path" => "/tmp/WORKFLOW.md",
        "hostname" => hostname(),
        "os_pid" => 9_999_999,
        "node" => "nonode@nohost",
        "guard_pid" => "#PID<0.0.0>",
        "started_at" => "2026-04-14T00:00:00Z"
      })
    )

    guard = start_temporary_guard!(lock_path: lock_path)

    assert Process.alive?(guard)

    {:ok, metadata} = lock_path |> File.read!() |> Jason.decode()
    assert metadata["os_pid"] == String.to_integer(System.pid())
    refute metadata["guard_pid"] == "#PID<0.0.0>"
  end

  defp temp_lock_path(prefix) do
    Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}.lock")
  end

  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> List.to_string(name)
      _other -> System.get_env("HOSTNAME") || "unknown-host"
    end
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) do
    cond do
      fun.() ->
        :ok

      attempts <= 0 ->
        flunk("condition not met in time")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  defp start_temporary_guard!(opts) do
    start_supervised!(%{
      id: make_ref(),
      start: {SingleActiveGuard, :start_link, [opts]},
      restart: :temporary
    })
  end
end
