defmodule SymphonyEx.AutomationTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Automation
  alias SymphonyEx.Domain.Issue

  test "resolves night-worker mode inside and outside configured windows" do
    config =
      Automation.normalize(
        mode: :night_worker,
        services: ["sns"],
        night_worker: [
          timezone: "Etc/UTC",
          windows: [%{start: "23:00", end: "07:00"}],
          mode_during_window: :full_auto,
          mode_outside_window: :default
        ]
      )

    assert [%{start_minute: 1380, end_minute: 420}] = config[:night_worker][:windows]
    assert Automation.resolve_mode(config, ~U[2026-05-22 23:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 06:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 12:00:00Z]) == :default
  end

  test "resolves same-day night-worker windows with configured timezone" do
    config =
      Automation.normalize(
        mode: :night_worker,
        night_worker: [
          timezone: "Asia/Seoul",
          windows: [%{start: "08:00", end: "10:00"}],
          mode_during_window: :full_auto,
          mode_outside_window: :default
        ]
      )

    assert [%{start_minute: 480, end_minute: 600}] = config[:night_worker][:windows]
    assert Automation.resolve_mode(config, ~U[2026-05-22 00:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 02:00:00Z]) == :default
  end

  test "resolves multiple night-worker windows" do
    config =
      Automation.normalize(
        mode: :night_worker,
        night_worker: [
          timezone: "Etc/UTC",
          windows: [%{start: "08:00", end: "09:00"}, %{start: "18:00", end: "19:00"}]
        ]
      )

    assert Automation.resolve_mode(config, ~U[2026-05-22 08:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 18:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 12:00:00Z]) == :default
  end

  test "exposes configured and effective mode status" do
    config =
      Automation.normalize(
        mode: :night_worker,
        night_worker: [
          timezone: "Etc/UTC",
          windows: [%{start: "23:00", end: "07:00"}]
        ]
      )

    assert Automation.mode_status(config, ~U[2026-05-22 23:30:00Z]) == %{
             configured_mode: :night_worker,
             effective_mode: :full_auto,
             night_worker: %{
               timezone: "Etc/UTC",
               active: true,
               in_window: true,
               mode_during_window: :full_auto,
               mode_outside_window: :default,
               windows: [%{start: "23:00", end: "07:00", start_minute: 1380, end_minute: 420}]
             }
           }
  end

  test "validates night-worker timezone names" do
    config =
      Automation.normalize(
        mode: :night_worker,
        night_worker: [
          timezone: "Not/AZone",
          windows: [%{start: "23:00", end: "07:00"}]
        ]
      )

    assert_raise ArgumentError, ~r/valid IANA timezone/, fn ->
      Automation.validate!(config)
    end
  end

  test "validates night-worker time format" do
    assert_raise ArgumentError, ~r/HH:MM/, fn ->
      Automation.normalize(
        mode: :night_worker,
        night_worker: [
          timezone: "Etc/UTC",
          windows: [%{start: "25:00", end: "07:00"}]
        ]
      )
    end
  end

  test "ignores unknown reviewbot keys instead of treating them as actor logins" do
    config =
      Automation.normalize(
        reviewbot: %{
          "actors" => ["gemini-code-assist"],
          "enabled" => true,
          "unrelated-key" => ["should-not-be-treated-as-actor"]
        }
      )

    assert config[:reviewbot][:actors] == ["gemini-code-assist"]
    assert MapSet.equal?(config[:reviewbot][:actors_set], MapSet.new(["gemini-code-assist"]))
  end

  test "derives service from title prefix or configured service label" do
    config = Automation.normalize(services: ["sns", "recipe", "todo"])

    assert Automation.issue_service(issue_fixture("SNS: add profile feed"), config) == "sns"

    assert Automation.issue_service(
             issue_fixture("Add importer", labels: ["service:recipe"]),
             config
           ) == "recipe"
  end

  test "derives canonical service from configured title prefix alias" do
    config =
      Automation.normalize(services: ["sns-manager"], service_aliases: %{"sns" => "sns-manager"})

    assert Automation.issue_service(issue_fixture("[sns] Upload adapter 범위 결정"), config) ==
             "sns-manager"
  end

  test "rejects service aliases absent from automation services" do
    config =
      Automation.normalize(services: ["sns-manager"], service_aliases: %{"sns" => "legacy-sns"})

    assert_raise ArgumentError,
                 ~r/automation\.service_aliases\.sns targets service "legacy-sns" not present in automation\.services/,
                 fn -> Automation.validate!(config) end
  end

  test "rejects issue service labels absent from automation services" do
    config = Automation.normalize(services: ["sns"])

    assert Automation.issue_service(
             issue_fixture("Add importer", labels: ["service:recipe"]),
             config
           ) ==
             {:error, {:unknown_service, "recipe"}}
  end

  test "requires trusted issue author metadata when trust policy is enabled" do
    config =
      Automation.normalize(
        issue_trust: [
          require_trusted_author: true,
          allowed_associations: ["OWNER", "MEMBER", "COLLABORATOR"],
          allowed_actors: []
        ]
      )

    assert Automation.issue_trust_result(
             issue_fixture("Untrusted", author_association: "CONTRIBUTOR"),
             config
           ) ==
             {:error, :untrusted_issue_author}

    assert Automation.issue_trust_result(
             issue_fixture("None", author_association: "NONE"),
             config
           ) ==
             {:error, :untrusted_issue_author}

    assert Automation.issue_trust_result(issue_fixture("Missing"), config) ==
             {:error, :missing_issue_author_trust}
  end

  test "allows configured trusted associations and actor logins" do
    config =
      Automation.normalize(
        issue_trust: [
          require_trusted_author: true,
          allowed_associations: ["OWNER", "MEMBER", "COLLABORATOR"],
          allowed_actors: ["Trusted-Bot"]
        ]
      )

    assert Automation.issue_trust_result(
             issue_fixture("Member", author_association: "MEMBER"),
             config
           ) ==
             :ok

    assert Automation.issue_trust_result(
             issue_fixture("Bot", author_login: "trusted-bot", author_association: "NONE"),
             config
           ) == :ok
  end

  test "trust policy is disabled by default for backward-compatible library use" do
    config = Automation.normalize([])

    assert Automation.issue_trust_result(issue_fixture("Legacy"), config) == :ok
  end

  defp issue_fixture(title, attrs \\ []) do
    struct!(
      Issue,
      [
        id: "issue-1",
        identifier: "1",
        title: title,
        description: "",
        state: "Todo",
        priority: 0,
        labels: []
      ] ++ attrs
    )
  end
end
