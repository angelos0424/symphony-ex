defmodule SymphonyEx.Orchestrator.Lifecycle do
  @moduledoc """
  Configurable mapping from orchestrator run states to GitHub tracker lifecycle
  semantics (issue open/closed, project status field names, and additional
  GitHub Project field values).

  The default mapping mirrors the implicit behaviour that existed before this
  module was extracted, so existing callers are backward-compatible.

  ## Fields

    * `:issue_state_mapping` — maps `{run_state, result}` tuples to `:open` or
      `:closed` GitHub issue states.
    * `:project_status_mapping` — maps `{run_state, result}` tuples to GitHub
      Project status field names (e.g. `"In Progress"`, `"Done"`).
    * `:project_field_mapping` — maps `{run_state, result}` tuples to arbitrary
      GitHub Project field name/value pairs (for example owner, ETA, or effort).
  """

  @type issue_state :: :open | :closed
  @type run_state :: :claimed | :running | :retry_queued | :released
  @type result_key :: :success | :failed | :cancelled | :any
  @type project_field_value :: String.t() | number() | nil

  @type issue_state_mapping :: %{{run_state(), result_key()} => issue_state()}
  @type project_status_mapping :: %{{run_state(), result_key()} => String.t()}
  @type project_field_mapping :: %{
          {run_state(), result_key()} => %{String.t() => project_field_value()}
        }

  @type t :: %__MODULE__{
          issue_state_mapping: issue_state_mapping(),
          project_status_mapping: project_status_mapping(),
          project_field_mapping: project_field_mapping()
        }

  @enforce_keys []
  defstruct issue_state_mapping: %{
              {:claimed, :any} => :open,
              {:running, :any} => :open,
              {:retry_queued, :any} => :open,
              {:released, :success} => :closed,
              {:released, :any} => :open
            },
            project_status_mapping: %{
              {:claimed, :any} => "In Progress",
              {:running, :any} => "In Progress",
              {:retry_queued, :any} => "Todo",
              {:released, :success} => "Done",
              {:released, :any} => "Todo"
            },
            project_field_mapping: %{}

  @doc """
  Returns the default lifecycle mapping.
  """
  @spec default() :: t()
  def default, do: %__MODULE__{}

  @doc """
  Builds a lifecycle struct from keyword options, merging with defaults.

  Accepts `:issue_state_mapping`, `:project_status_mapping`, and/or
  `:project_field_mapping` keys.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    default = %__MODULE__{}

    %__MODULE__{
      issue_state_mapping:
        Map.merge(
          default.issue_state_mapping,
          Keyword.get(opts, :issue_state_mapping, %{})
        ),
      project_status_mapping:
        Map.merge(
          default.project_status_mapping,
          Keyword.get(opts, :project_status_mapping, %{})
        ),
      project_field_mapping:
        default.project_field_mapping
        |> Map.merge(Keyword.get(opts, :project_field_mapping, %{}))
        |> normalize_project_field_mapping()
    }
  end

  @spec normalize_project_field_mapping(map()) :: project_field_mapping()
  defp normalize_project_field_mapping(mapping) do
    mapping
    |> Enum.map(fn {state_key, fields} -> {state_key, normalize_project_fields(fields)} end)
    |> Map.new()
  end

  @spec normalize_project_fields(term()) :: %{String.t() => project_field_value()}
  defp normalize_project_fields(fields) when is_map(fields) do
    fields
    |> Enum.filter(fn {_name, value} -> supported_project_field_value?(value) end)
    |> Map.new()
  end

  defp normalize_project_fields(_fields), do: %{}

  @spec supported_project_field_value?(term()) :: boolean()
  defp supported_project_field_value?(value)

  defp supported_project_field_value?(value) when is_binary(value), do: true
  defp supported_project_field_value?(value) when is_number(value), do: true
  defp supported_project_field_value?(nil), do: true
  defp supported_project_field_value?(_value), do: false

  @doc """
  Resolves the desired GitHub issue state (`:open` or `:closed`) for the given
  run state and result.
  """
  @spec resolve_issue_state(t(), run_state(), atom() | nil) :: issue_state()
  def resolve_issue_state(%__MODULE__{} = lifecycle, run_state, result) do
    result = result || :any

    lifecycle.issue_state_mapping[{run_state, result}] ||
      lifecycle.issue_state_mapping[{run_state, :any}] ||
      :open
  end

  @doc """
  Resolves the desired GitHub Project status field name for the given run state
  and result. Returns `nil` when no mapping exists.
  """
  @spec resolve_project_status(t(), run_state(), atom() | nil) :: String.t() | nil
  def resolve_project_status(%__MODULE__{} = lifecycle, run_state, result) do
    result = result || :any

    lifecycle.project_status_mapping[{run_state, result}] ||
      lifecycle.project_status_mapping[{run_state, :any}]
  end

  @doc """
  Resolves additional GitHub Project field name/value pairs for the given run
  state and result. Returns an empty map when no mapping exists.
  """
  @spec resolve_project_fields(t(), run_state(), atom() | nil) :: %{
          String.t() => project_field_value()
        }
  def resolve_project_fields(%__MODULE__{} = lifecycle, run_state, result) do
    result = result || :any

    lifecycle.project_field_mapping[{run_state, result}] ||
      lifecycle.project_field_mapping[{run_state, :any}] ||
      %{}
  end
end
