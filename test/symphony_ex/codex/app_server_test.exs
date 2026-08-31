defmodule SymphonyEx.Codex.AppServerTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Codex.AppServer

  test "runs the Codex process with only the explicit agent environment" do
    workspace =
      Path.join(System.tmp_dir!(), "app-server-env-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)

    previous_values =
      Enum.map(
        ["GITHUB_TOKEN", "GITHUB_TRACKER_TOKEN", "SYMPHONY_DASHBOARD_SECRET_KEY_BASE"],
        &{&1, System.get_env(&1)}
      )

    System.put_env("GITHUB_TOKEN", "parent-tracker-token")
    System.put_env("GITHUB_TRACKER_TOKEN", "tracker-test-token")
    System.put_env("SYMPHONY_DASHBOARD_SECRET_KEY_BASE", "dashboard-test-secret")

    on_exit(fn ->
      Enum.each(previous_values, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    command = ~S"""
    if [ "${GITHUB_TOKEN:-}" = "agent-test-token" ] && \
      [ -z "${GITHUB_TRACKER_TOKEN:-}" ] && \
      [ -z "${SYMPHONY_DASHBOARD_SECRET_KEY_BASE:-}" ]; then
      printf "{\"id\":1,\"result\":{\"safe\":true}}\n"
    else
      printf "{\"id\":1,\"result\":{\"safe\":false}}\n"
    fi
    sleep 2
    """

    env = [
      {~c"PATH", System.get_env("PATH") |> to_charlist()},
      {~c"TERM", ~c"dumb"},
      {~c"GITHUB_TOKEN", ~c"agent-test-token"},
      {~c"GITHUB_AGENT_TOKEN", ~c"agent-test-token"},
      {~c"GITHUB_TRACKER_TOKEN", false},
      {~c"SYMPHONY_DASHBOARD_SECRET_KEY_BASE", false}
    ]

    {:ok, server} = AppServer.start_link(command: command, cwd: workspace, env: env)

    assert {:ok, %{"safe" => true}} = AppServer.initialize(server)
    assert AppServer.alive?(server)
    assert :sys.get_state(server).env == []
    assert :ok = AppServer.shutdown(server)
  end

  test "deployment templates keep tracker and agent credentials separated" do
    root = Path.expand("../../../", __DIR__)
    entrypoint = File.read!(Path.join(root, "deploy/docker/entrypoint.sh"))
    common_env = File.read!(Path.join(root, "deploy/docker/env/common.env.example"))

    assert entrypoint =~ "GITHUB_AGENT_TOKEN"
    assert entrypoint =~ "GITHUB_TRACKER_TOKEN"
    assert entrypoint =~ "credential.helper"
    refute entrypoint =~ "url.\"https://x-access-token:"
    assert entrypoint =~ "remove_legacy_git_auth_config"
    assert common_env =~ "GITHUB_TRACKER_TOKEN="
    assert common_env =~ "GITHUB_AGENT_TOKEN="

    for compose_file <- [
          "docker-compose.repo-a.yml",
          "docker-compose.repo-b.yml",
          "docker-compose.repo-c.yml"
        ] do
      compose = File.read!(Path.join(root, "deploy/docker/#{compose_file}"))
      assert compose =~ "./env/common.env"
      assert compose =~ "separate tracker and agent credentials"
    end
  end
end
