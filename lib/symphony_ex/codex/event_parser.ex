defmodule SymphonyEx.Codex.EventParser do
  @moduledoc """
  Parses JSON-RPC notifications from the Codex app-server into structured events.
  """

  alias SymphonyEx.Domain.Events

  @event_map %{
    "turn_started" => :turn_started,
    "turn_completed" => :turn_completed,
    "turn_failed" => :turn_failed,
    "turn_cancelled" => :turn_cancelled,
    "turn_canceled" => :turn_cancelled,
    "agent_message" => :agent_message,
    "approval_requested" => :approval_requested,
    "tool_call_requested" => :tool_call_requested,
    "item_started" => :item_started,
    "item_completed" => :item_completed,
    "diff_updated" => :diff_updated,
    "notification" => :notification
  }

  @item_events [:item_started, :item_completed]

  @spec parse(map()) :: Events.t()
  def parse(%{method: method, params: params}) do
    event_name = classify_event(method, params)

    %Events{
      event: event_name,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      raw_method: method,
      message: extract_message(params),
      params: params,
      usage: extract_usage(params)
    }
  end

  @spec classify_event(String.t(), map()) :: Events.event_name()
  defp classify_event(method, params) do
    # Normalize method name
    normalized =
      method
      |> String.replace("/", "_")
      |> String.replace(".", "_")

    # Check direct method mapping
    case Map.get(@event_map, normalized) do
      nil -> classify_from_params(normalized, params)
      event -> event |> maybe_reclassify_item_event(params) |> maybe_reclassify_turn_event(params)
    end
  end

  @spec maybe_reclassify_turn_event(Events.event_name(), map()) :: Events.event_name()
  defp maybe_reclassify_turn_event(:turn_completed, params) do
    case turn_status(params) do
      "interrupted" -> :turn_cancelled
      "failed" -> :turn_failed
      _status -> :turn_completed
    end
  end

  defp maybe_reclassify_turn_event(event, _params), do: event

  @spec turn_status(map()) :: String.t() | nil
  defp turn_status(params) do
    case get_in(params, ["turn", "status"]) || params["status"] do
      status when is_binary(status) -> String.downcase(status)
      _other -> nil
    end
  end

  @spec classify_from_params(String.t(), map()) :: Events.event_name()
  defp classify_from_params(method, params) do
    # Check for event type hints in params
    event_types = extract_event_types(params)

    cond do
      "turn_completed" in event_types ->
        :turn_completed

      "turn_failed" in event_types ->
        :turn_failed

      "approval_requested" in event_types ->
        :approval_requested

      "tool_call_requested" in event_types ->
        :tool_call_requested

      String.contains?(method, "completed") and not String.contains?(method, "item") ->
        :turn_completed

      String.contains?(method, "failed") ->
        :turn_failed

      true ->
        :notification
    end
  end

  # Item events should not be classified as turn events
  @spec maybe_reclassify_item_event(Events.event_name(), map()) :: Events.event_name()
  defp maybe_reclassify_item_event(event, _params) when event in @item_events, do: event
  defp maybe_reclassify_item_event(event, _params), do: event

  @spec extract_event_types(map()) :: [String.t()]
  defp extract_event_types(params) do
    case params do
      %{"type" => type} when is_binary(type) -> [type]
      %{"event" => event} when is_binary(event) -> [event]
      %{"types" => types} when is_list(types) -> types
      _ -> []
    end
  end

  @spec extract_message(map()) :: String.t() | nil
  defp extract_message(params) do
    params["message"] || params["content"] || params["text"] ||
      get_in(params, ["data", "message"]) || get_in(params, ["data", "content"]) ||
      get_in(params, ["turn", "error", "message"]) || turn_status_message(turn_status(params))
  end

  defp turn_status_message("interrupted"), do: "Turn interrupted"
  defp turn_status_message("failed"), do: "Turn failed"
  defp turn_status_message(_status), do: nil

  @spec extract_usage(map()) :: Events.usage() | nil
  defp extract_usage(%{"usage" => %{} = usage}) do
    %{
      input_tokens: usage["input_tokens"] || usage["inputTokens"] || 0,
      output_tokens: usage["output_tokens"] || usage["outputTokens"] || 0,
      total_tokens: usage["total_tokens"] || usage["totalTokens"] || 0
    }
  end

  defp extract_usage(_), do: nil
end
