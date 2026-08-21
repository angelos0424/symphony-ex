defmodule SymphonyEx.Codex.EventParserTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.Codex.EventParser

  test "classifies interrupted turn/completed notifications as cancelled" do
    event =
      EventParser.parse(%{
        method: "turn/completed",
        params: %{
          "threadId" => "thread-1",
          "turn" => %{"id" => "turn-1", "status" => "interrupted"}
        }
      })

    assert event.event == :turn_cancelled
    assert event.message == "Turn interrupted"
  end

  test "keeps genuinely completed turn/completed notifications successful" do
    event =
      EventParser.parse(%{
        method: "turn/completed",
        params: %{
          "threadId" => "thread-1",
          "turn" => %{"id" => "turn-1", "status" => "completed"}
        }
      })

    assert event.event == :turn_completed
  end
end
