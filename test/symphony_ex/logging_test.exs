defmodule SymphonyEx.LoggingTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.Logging

  test "normalizes structured dispatch metadata" do
    issue = %Issue{
      id: "issue-1",
      identifier: "SYM-1",
      title: "Test",
      description: "body",
      state: "Todo",
      priority: 42
    }

    metadata =
      Logging.dispatch_metadata(
        issue,
        :serialized_conflict,
        :code,
        MapSet.new(["path:lib/a.ex", "service:api"])
      )

    assert metadata.issue_id == "issue-1"
    assert metadata.issue_identifier == "SYM-1"
    assert metadata.issue_state == "Todo"
    assert metadata.issue_priority == 42
    assert metadata.gating_reason == :serialized_conflict
    assert metadata.class == :code
    assert metadata.conflict_keys == ["path:lib/a.ex", "service:api"]
  end

  test "maps run outcomes to stable outcome kinds" do
    assert Logging.outcome_kind(:success, nil) == "progressed"
    assert Logging.outcome_kind(:cancelled, nil) == "blocked"
    assert Logging.outcome_kind(:failed, "plain failure") == "failed"
    assert Logging.outcome_kind(:failed, "No-op: nothing to change") == "no_op"
  end
end
