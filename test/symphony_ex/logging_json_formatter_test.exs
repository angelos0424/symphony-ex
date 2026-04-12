defmodule SymphonyEx.LoggingJSONFormatterTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Logging
  alias SymphonyEx.Logging.JSONFormatter

  test "formats logger events as json with structured metadata" do
    event = %{
      level: :info,
      msg: {:string, "issue dispatched"},
      meta: %{
        time: System.system_time(:microsecond),
        issue_identifier: "SYM-42",
        thread_id: "thread-1",
        recovered: true,
        conflict_keys: ["service:api"],
        pid: self()
      }
    }

    json =
      event |> JSONFormatter.format(%{metadata: :all}) |> IO.iodata_to_binary() |> String.trim()

    decoded = Jason.decode!(json)

    assert decoded["level"] == "info"
    assert decoded["message"] == "issue dispatched"
    assert decoded["metadata"]["issue_identifier"] == "SYM-42"
    assert decoded["metadata"]["thread_id"] == "thread-1"
    assert decoded["metadata"]["recovered"] == true
    assert decoded["metadata"]["conflict_keys"] == ["service:api"]
    assert is_binary(decoded["timestamp"])
    assert is_binary(decoded["pid"])
  end

  test "redacts sensitive metadata keys and truncates oversized metadata values" do
    event = %{
      level: :info,
      msg: {:string, "session updated"},
      meta: %{
        time: System.system_time(:microsecond),
        issue_identifier: "SYM-77",
        api_key: "secret-token",
        nested: %{authorization: "Bearer abc123", note: String.duplicate("x", 32)}
      }
    }

    json =
      event
      |> JSONFormatter.format(%{
        metadata: :all,
        redact_keys: [:api_key, :authorization],
        max_metadata_value_length: 16
      })
      |> IO.iodata_to_binary()
      |> String.trim()

    decoded = Jason.decode!(json)

    assert decoded["metadata"]["api_key"] == "[REDACTED]"
    assert decoded["metadata"]["nested"]["authorization"] == "[REDACTED]"
    assert decoded["metadata"]["nested"]["note"] == "xx...[truncated]"
  end

  test "runtime logger activation switches default handler formatter to json" do
    original = :logger.get_handler_config(:default)

    try do
      assert :ok =
               Logging.configure_json_logger(
                 metadata: [:issue_identifier, :thread_id],
                 redact_keys: [:api_key],
                 max_metadata_value_length: 128
               )

      assert {:ok, handler} = :logger.get_handler_config(:default)

      assert handler.formatter ==
               {JSONFormatter,
                %{
                  metadata: [:issue_identifier, :thread_id],
                  timestamp_format: :iso8601,
                  redact_keys: [:api_key],
                  max_metadata_value_length: 128
                }}
    after
      restore_handler_formatter(original)
    end
  end

  defp restore_handler_formatter({:ok, %{formatter: formatter}}) do
    :ok = :logger.update_handler_config(:default, :formatter, formatter)
  end
end
