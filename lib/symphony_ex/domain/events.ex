defmodule SymphonyEx.Domain.Events do
  @moduledoc """
  App-server event types and structs.
  """

  @type event_name ::
          :turn_started
          | :turn_completed
          | :turn_failed
          | :turn_cancelled
          | :agent_message
          | :approval_requested
          | :tool_call_requested
          | :item_started
          | :item_completed
          | :diff_updated
          | :notification
          | :unknown

  @type t :: %__MODULE__{
          event: event_name(),
          timestamp: String.t(),
          raw_method: String.t() | nil,
          message: String.t() | nil,
          params: map(),
          usage: usage() | nil
        }

  @type usage :: %{
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          total_tokens: non_neg_integer()
        }

  defstruct [
    :event,
    :timestamp,
    :raw_method,
    :message,
    :usage,
    params: %{}
  ]

  @terminal_events [:turn_completed, :turn_failed, :turn_cancelled]

  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{event: event}), do: event in @terminal_events

  @spec control_event?(t()) :: boolean()
  def control_event?(%__MODULE__{event: event}),
    do: event in [:approval_requested, :tool_call_requested]
end
