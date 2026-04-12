defmodule SymphonyEx.Logging.JSONFormatter do
  @moduledoc """
  Minimal JSON logger formatter for Erlang/Elixir `:logger`.

  This keeps the app self-contained while still providing a real structured-log
  backend/config path that can be activated from workflow/env runtime config.
  """

  @behaviour :logger_formatter

  @type config :: map()

  @default_timestamp_format :iso8601
  @redacted_value "[REDACTED]"
  @truncated_suffix "...[truncated]"

  @spec check_config(config()) :: :ok
  def check_config(config) when is_map(config) do
    _ = config
    :ok
  end

  @spec format(:logger.log_event(), config()) :: IO.chardata()
  def format(event, config) do
    json =
      event
      |> event_payload(config)
      |> Jason.encode_to_iodata!()

    [json, ?\n]
  end

  @spec event_payload(:logger.log_event(), config()) :: map()
  defp event_payload(event, config) do
    meta = Map.get(event, :meta, %{})

    %{
      "timestamp" => format_timestamp(Map.get(meta, :time), config),
      "level" => event |> Map.get(:level, :info) |> to_string(),
      "message" => format_message(Map.get(event, :msg)),
      "metadata" => format_metadata(meta, config)
    }
    |> maybe_put("logger", meta[:logger])
    |> maybe_put("application", meta[:application])
    |> maybe_put("module", meta[:module] && inspect(meta[:module]))
    |> maybe_put("function", format_function(meta[:function]))
    |> maybe_put("file", meta[:file] && List.to_string(meta[:file]))
    |> maybe_put("line", meta[:line])
    |> maybe_put("pid", meta[:pid] && inspect(meta[:pid]))
  end

  @spec format_timestamp(term(), config()) :: String.t()
  defp format_timestamp(nil, _config),
    do: DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()

  defp format_timestamp(time, config) do
    case Map.get(config, :timestamp_format, @default_timestamp_format) do
      :iso8601 ->
        time
        |> :calendar.system_time_to_rfc3339(unit: :microsecond)
        |> IO.iodata_to_binary()

      _other ->
        inspect(time)
    end
  rescue
    _error -> DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
  end

  @spec format_message(term()) :: String.t()
  defp format_message({:string, message}) do
    IO.iodata_to_binary(message)
  end

  defp format_message({report, _opts}) do
    inspect(report)
  end

  defp format_message(message) when is_binary(message), do: message
  defp format_message(message), do: inspect(message)

  @spec format_metadata(map(), config()) :: map()
  defp format_metadata(meta, config) do
    metadata_keys = Map.get(config, :metadata, :all)
    redacted_keys = normalized_redact_keys(config)
    max_value_length = Map.get(config, :max_metadata_value_length, 2_048)

    meta
    |> Map.drop([:time, :gl, :domain, :mfa, :report_cb])
    |> maybe_take_metadata(metadata_keys)
    |> Enum.map(fn {key, value} ->
      {
        to_string(key),
        normalize_value(value,
          key: key,
          redacted_keys: redacted_keys,
          max_metadata_value_length: max_value_length
        )
      }
    end)
    |> Map.new()
  end

  @spec maybe_take_metadata(map(), :all | [atom()]) :: map()
  defp maybe_take_metadata(meta, :all), do: meta
  defp maybe_take_metadata(meta, keys) when is_list(keys), do: Map.take(meta, keys)

  @spec format_function(term()) :: String.t() | nil
  defp format_function({name, arity}), do: "#{name}/#{arity}"
  defp format_function(_other), do: nil

  @spec normalize_value(term(), keyword()) :: term()
  defp normalize_value(value, opts) do
    if redacted_key?(Keyword.get(opts, :key), Keyword.fetch!(opts, :redacted_keys)) do
      @redacted_value
    else
      do_normalize_value(value, opts)
    end
  end

  defp do_normalize_value(value, opts) when is_binary(value) do
    truncate_binary(value, Keyword.fetch!(opts, :max_metadata_value_length))
  end

  defp do_normalize_value(value, _opts) when is_number(value), do: value
  defp do_normalize_value(value, _opts) when is_boolean(value), do: value
  defp do_normalize_value(value, _opts) when is_atom(value), do: Atom.to_string(value)

  defp do_normalize_value(value, opts) when is_list(value) do
    if Keyword.keyword?(value) do
      truncate_inspect(value, opts)
    else
      Enum.map(value, &normalize_value(&1, Keyword.delete(opts, :key)))
    end
  end

  defp do_normalize_value(value, opts) when is_map(value) do
    value
    |> Enum.map(fn {k, v} ->
      {to_string(k), normalize_value(v, Keyword.put(opts, :key, k))}
    end)
    |> Map.new()
  end

  defp do_normalize_value(value, opts), do: truncate_inspect(value, opts)

  @spec maybe_put(map(), String.t(), term()) :: map()
  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @spec normalized_redact_keys(config()) :: MapSet.t(String.t())
  defp normalized_redact_keys(config) do
    config
    |> Map.get(:redact_keys, [])
    |> Enum.map(&normalize_key_name/1)
    |> MapSet.new()
  end

  @spec redacted_key?(term(), MapSet.t(String.t())) :: boolean()
  defp redacted_key?(nil, _redacted_keys), do: false

  defp redacted_key?(key, redacted_keys) do
    MapSet.member?(redacted_keys, normalize_key_name(key))
  end

  @spec normalize_key_name(term()) :: String.t()
  defp normalize_key_name(key) do
    key
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec truncate_binary(String.t(), pos_integer()) :: String.t()
  defp truncate_binary(value, max_length) when byte_size(value) <= max_length, do: value

  defp truncate_binary(value, max_length) do
    prefix_length = max(max_length - byte_size(@truncated_suffix), 0)
    binary_part(value, 0, prefix_length) <> @truncated_suffix
  end

  @spec truncate_inspect(term(), keyword()) :: String.t()
  defp truncate_inspect(value, opts) do
    value
    |> inspect()
    |> truncate_binary(Keyword.fetch!(opts, :max_metadata_value_length))
  end
end
