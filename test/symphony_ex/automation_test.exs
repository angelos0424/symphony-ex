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

    assert Automation.resolve_mode(config, ~U[2026-05-22 23:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 06:30:00Z]) == :full_auto
    assert Automation.resolve_mode(config, ~U[2026-05-22 12:00:00Z]) == :default
  end

  test "derives service from title prefix or configured service label" do
    config = Automation.normalize(services: ["sns", "recipe", "todo"])

    assert Automation.issue_service(issue_fixture("SNS: add profile feed"), config) == "sns"

    assert Automation.issue_service(
             issue_fixture("Add importer", labels: ["service:recipe"]),
             config
           ) == "recipe"
  end

  test "rejects issue service labels absent from automation services" do
    config = Automation.normalize(services: ["sns"])

    assert Automation.issue_service(
             issue_fixture("Add importer", labels: ["service:recipe"]),
             config
           ) ==
             {:error, {:unknown_service, "recipe"}}
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
