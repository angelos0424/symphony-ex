defmodule SymphonyEx.Logging do
  @moduledoc """
  Shared helpers for structured log metadata and runtime logger activation.

  Phase 3 now includes a real JSON logger formatter path so orchestrator /
  runner / recovery flows can emit structured metadata through Logger in a
  machine-readable runtime configuration.
  """

  require Logger

  alias SymphonyEx.Logging.JSONFormatter

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.SessionStore

  @default_redacted_metadata_keys [
    :api_key,
    :authorization,
    :cookie,
    :cookies,
    :password,
    :passwd,
    :secret,
    :token,
    :access_token,
    :refresh_token
  ]

  @default_max_metadata_value_length 2_048

  @type metadata_scalar :: nil | String.t() | number() | boolean() | atom()
  @type metadata_value :: metadata_scalar() | [metadata_scalar()]
  @type metadata_map :: %{optional(atom()) => metadata_value()}

  @spec issue_metadata(Issue.t() | nil) :: metadata_map()
  def issue_metadata(nil), do: %{}

  def issue_metadata(%Issue{} = issue) do
    %{
      issue_id: issue.id,
      issue_identifier: issue.identifier,
      issue_state: issue.state,
      issue_priority: issue.priority
    }
  end

  @spec session_metadata(SessionStore.session_data() | nil) :: metadata_map()
  def session_metadata(nil), do: %{}

  def session_metadata(session) do
    recovery_count = Map.get(session, :recovery_count, 0)

    %{
      session_id: Map.get(session, :session_id),
      thread_id: Map.get(session, :thread_id),
      turn_id: Map.get(session, :turn_id),
      recovery_count: recovery_count,
      last_event: Map.get(session, :last_event),
      session_phase: Map.get(session, :phase),
      error_category: Map.get(session, :error_category),
      recovered: recovery_count > 0
    }
  end

  @spec dispatch_metadata(Issue.t(), atom(), atom(), [String.t()] | MapSet.t(String.t())) ::
          metadata_map()
  def dispatch_metadata(%Issue{} = issue, gating_reason, class, conflict_keys) do
    issue_metadata(issue)
    |> Map.merge(%{
      gating_reason: gating_reason,
      class: class,
      conflict_keys: normalize_conflict_keys(conflict_keys)
    })
  end

  @spec run_metadata(Issue.t(), keyword()) :: metadata_map()
  def run_metadata(%Issue{} = issue, opts \\ []) do
    issue_metadata(issue)
    |> Map.merge(%{
      workspace_path: Keyword.get(opts, :workspace_path),
      thread_id: Keyword.get(opts, :thread_id),
      turn_id: Keyword.get(opts, :turn_id),
      session_id: Keyword.get(opts, :session_id),
      elapsed_ms: Keyword.get(opts, :elapsed_ms),
      outcome_kind: Keyword.get(opts, :outcome_kind),
      error_category: Keyword.get(opts, :error_category),
      recovered: Keyword.get(opts, :recovered),
      recovery_count: Keyword.get(opts, :recovery_count),
      last_event: Keyword.get(opts, :last_event)
    })
  end

  @spec logger_metadata(metadata_map()) :: keyword()
  def logger_metadata(metadata) when is_map(metadata) do
    metadata
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.map(fn {key, value} -> {key, normalize_value(value)} end)
  end

  @spec merge_logger_metadata([metadata_map()]) :: keyword()
  def merge_logger_metadata(parts) when is_list(parts) do
    parts
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
    |> logger_metadata()
  end

  @spec normalize_conflict_keys([String.t()] | MapSet.t(String.t()) | nil) :: [String.t()] | nil
  def normalize_conflict_keys(nil), do: nil
  def normalize_conflict_keys(%MapSet{} = keys), do: keys |> MapSet.to_list() |> Enum.sort()
  def normalize_conflict_keys(keys) when is_list(keys), do: Enum.sort(keys)

  @spec outcome_kind(:success | :failed | :cancelled, String.t() | nil) :: String.t()
  def outcome_kind(:success, _error), do: "progressed"
  def outcome_kind(:cancelled, _error), do: "blocked"
  def outcome_kind(:failed, nil), do: "failed"

  def outcome_kind(:failed, error) when is_binary(error) do
    if String.contains?(String.downcase(error), "no-op"), do: "no_op", else: "failed"
  end

  @spec with_metadata(metadata_map() | [metadata_map()], (-> result)) :: result when result: var
  def with_metadata(metadata_or_parts, fun) when is_function(fun, 0) do
    metadata =
      case metadata_or_parts do
        parts when is_list(parts) -> merge_logger_metadata(parts)
        %{} = map -> logger_metadata(map)
      end

    Logger.metadata(metadata)

    try do
      fun.()
    after
      Logger.reset_metadata()
    end
  end

  @type logger_mode :: :pretty | :json

  @spec default_redacted_metadata_keys() :: [atom()]
  def default_redacted_metadata_keys, do: @default_redacted_metadata_keys

  @spec default_max_metadata_value_length() :: pos_integer()
  def default_max_metadata_value_length, do: @default_max_metadata_value_length

  @spec configure_logger(keyword()) :: :ok
  def configure_logger(opts) when is_list(opts) do
    case Keyword.get(opts, :format, :pretty) do
      :json -> configure_json_logger(opts)
      "json" -> configure_json_logger(opts)
      _other -> configure_pretty_logger()
    end
  end

  @spec configure_json_logger(keyword()) :: :ok
  def configure_json_logger(opts \\ []) do
    metadata_keys = Keyword.get(opts, :metadata, :all)
    level = Keyword.get(opts, :level)
    redact_keys = Keyword.get(opts, :redact_keys, @default_redacted_metadata_keys)

    max_metadata_value_length =
      Keyword.get(opts, :max_metadata_value_length, @default_max_metadata_value_length)

    :ok =
      :logger.update_handler_config(:default, :formatter, {
        JSONFormatter,
        %{
          metadata: metadata_keys,
          timestamp_format: :iso8601,
          redact_keys: redact_keys,
          max_metadata_value_length: max_metadata_value_length
        }
      })

    if is_atom(level) do
      Logger.configure(level: level)
    end

    :ok
  end

  @spec configure_pretty_logger() :: :ok
  def configure_pretty_logger do
    :ok = :logger.update_handler_config(:default, :formatter, {:logger_formatter, %{}})
    :ok
  end

  @spec normalize_value(metadata_value()) ::
          nil | String.t() | number() | boolean() | [String.t() | number() | boolean()]
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)

  defp normalize_value(values) when is_list(values) do
    Enum.map(values, fn
      value when is_atom(value) -> Atom.to_string(value)
      value -> value
    end)
  end

  defp normalize_value(value), do: value
end
