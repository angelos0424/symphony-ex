defmodule SymphonyEx.ConfigBoundsTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Config.Bounds
  alias SymphonyEx.Config.Schema
  alias SymphonyEx.RuntimeControl

  @valid_settings [
    poll_interval_ms: 1,
    max_concurrent: 1,
    max_retries: 0,
    backoff_base_ms: 1
  ]

  test "exposes one bounds contract to schema and runtime control" do
    bounds = %{
      poll_interval_ms: %{min: 1, max: 86_400_000},
      max_concurrent: %{min: 1, max: 32},
      max_retries: %{min: 0, max: 20},
      backoff_base_ms: %{min: 1, max: 86_400_000}
    }

    assert Bounds.bounds() == bounds
    assert Schema.runtime_bounds() == bounds
    assert RuntimeControl.settings_bounds() == bounds
  end

  test "accepts every configured boundary in the schema" do
    settings = [
      poll_interval_ms: 86_400_000,
      max_concurrent: 32,
      max_retries: 20,
      backoff_base_ms: 86_400_000
    ]

    assert Keyword.take(validated_config(settings)[:orchestrator], [
             :poll_interval_ms,
             :max_concurrent,
             :max_retries,
             :backoff_base_ms
           ]) == settings
  end

  test "rejects negative, non-integer, and over-limit schema values with field bounds" do
    for {field, value, expected_bound} <- [
          {:poll_interval_ms, 86_400_001, "1..86400000"},
          {:max_concurrent, 33, "1..32"},
          {:max_retries, -1, "0..20"},
          {:backoff_base_ms, "not-an-integer", "1..86400000"}
        ] do
      opts = Keyword.put(@valid_settings, field, value)

      assert {:error, error} =
               NimbleOptions.validate(
                 [tracker: valid_tracker(), workspace: valid_workspace(), orchestrator: opts],
                 Schema.schema()
               )

      message = Exception.message(error)
      assert message =~ Atom.to_string(field)
      assert message =~ expected_bound
    end
  end

  defp validated_config(settings) do
    Schema.validate!(
      tracker: valid_tracker(),
      workspace: valid_workspace(),
      orchestrator: settings
    )
  end

  defp valid_tracker do
    [api_key: "tracker-test-token", owner: "openai", repo: "symphony"]
  end

  defp valid_workspace do
    [root: "/tmp/worktrees", source_repo_path: "/tmp/source"]
  end
end
