defmodule SymphonyEx.Deploy.DockerHardeningTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../..", __DIR__)
  @docker_dir Path.join(@repo_root, "deploy/docker")
  @config_file Path.join(@repo_root, "config/config.exs")
  @runtime_canary Path.join(__DIR__, "docker_hardening_runtime.sh")
  @compose_files ~w(
    docker-compose.repo-a.yml
    docker-compose.repo-b.yml
    docker-compose.repo-c.yml
  )
  @workflow_files ~w(
    ../../WORKFLOW.md
    workflows/repo-a.WORKFLOW.md
    workflows/repo-b.WORKFLOW.md
    workflows/repo-c.WORKFLOW.md
  )

  test "runtime image is non-root and has dashboard-independent liveness" do
    dockerfile = read!("Dockerfile")

    assert dockerfile =~ "USER symphony"
    assert dockerfile =~ "HEALTHCHECK"
    assert dockerfile =~ "/proc/[0-9]*/comm"
    refute dockerfile =~ "/proc/1/comm"
    refute dockerfile =~ "SYMPHONY_DASHBOARD"
  end

  test "immutable release disables tzdata writes under the read-only app tree" do
    config = File.read!(@config_file)

    assert config =~ "config :tzdata, :autoupdate, :disabled"
  end

  test "entrypoint stages only Codex auth and config in the runtime home" do
    entrypoint = read!("entrypoint.sh")

    assert entrypoint =~ "/run/host-codex/auth.json"
    assert entrypoint =~ "/run/host-codex/config.toml"
    assert entrypoint =~ "Codex auth input is required"
    assert entrypoint =~ "must be a regular file"
    assert entrypoint =~ "not readable by runtime UID"
    assert entrypoint =~ "SYMPHONY_CODEX_FORCE_SEED"
    assert entrypoint =~ "CODEX_HOME"
    assert entrypoint =~ "/.codex}"
    refute entrypoint =~ "cp -a /run/host-codex/."
    refute entrypoint =~ "/root/.codex"
  end

  test "all compose variants enforce least privilege and bounded resources" do
    for file <- @compose_files do
      compose = read!(file)

      assert compose =~ "no-new-privileges:true", file
      assert compose =~ ~r/cap_drop:\s*\n\s*- ALL/, file
      assert compose =~ ~r/pids_limit:\s*\d+/, file
      assert compose =~ ~r/cpus:\s*"[0-9.]+"/, file
      assert compose =~ ~r/mem_limit:\s*\S+/, file
      assert compose =~ "source: ${SYMPHONY_CODEX_HOME}/auth.json", file
      assert compose =~ "target: /run/host-codex/auth.json", file
      assert compose =~ "source: ${SYMPHONY_CODEX_HOME}/config.toml", file
      assert compose =~ "target: /run/host-codex/config.toml", file
      assert length(Regex.scan(~r/create_host_path:\s*false/, compose)) == 2, file
      assert compose =~ "/home/symphony/.codex", file
      refute compose =~ "SYMPHONY_STATE_ROOT", file
      refute compose =~ "/.codex:/run/host-codex:ro", file
    end
  end

  test "all shipped workflows default Codex to workspaceWrite" do
    for file <- @workflow_files do
      workflow = read!(file)

      assert workflow =~ "thread-sandbox: workspaceWrite", file
      refute workflow =~ "thread-sandbox: dangerFullAccess", file
    end
  end

  test "runtime canary covers Compose init and private credential inputs" do
    canary = File.read!(@runtime_canary)

    assert canary =~ "--init"
    assert canary =~ "stat -c %a"
    assert canary =~ "mode=%s uid=%s gid=%s"
    assert canary =~ "health=healthy"
    assert canary =~ "runtime-refreshed-auth"
    assert canary =~ "SYMPHONY_CODEX_FORCE_SEED=true"
  end

  defp read!(relative_path) do
    @docker_dir
    |> Path.join(relative_path)
    |> File.read!()
  end
end
