defmodule SymphonyEx.GitHub.IssueBodyMetadata do
  @moduledoc """
  Parses structured GitHub issue body metadata used for dispatch eligibility.
  """

  @type t :: %__MODULE__{
          service: String.t() | nil,
          paths: [String.t()],
          release: String.t() | nil,
          conflict_hints: [String.t()],
          missing_required_fields: [atom()]
        }

  defstruct service: nil,
            paths: [],
            release: nil,
            conflict_hints: [],
            missing_required_fields: []

  @service_keys MapSet.new(["service", "services"])
  @path_keys MapSet.new(["path", "paths"])
  @release_keys MapSet.new(["release"])

  @conflict_hint_prefixes %{
    "scope" => nil,
    "conflict-scope" => nil,
    "conflict_scope" => nil,
    "service" => "service:",
    "services" => "service:",
    "path" => "path:",
    "paths" => "path:",
    "package" => "package:",
    "packages" => "package:",
    "release" => "release:"
  }

  @spec parse(String.t() | nil) :: t()
  def parse(body) do
    body
    |> to_string()
    |> String.split("\n")
    |> Enum.reduce(%__MODULE__{}, &parse_line/2)
    |> finalize()
  end

  @spec parse_line(String.t(), t()) :: t()
  defp parse_line(line, metadata) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" ->
        metadata

      not String.contains?(trimmed, ":") ->
        metadata

      true ->
        [raw_key, raw_values] = String.split(trimmed, ":", parts: 2)
        key = normalize_value(raw_key)
        values = parse_values(raw_values)

        metadata
        |> update_field(key, values)
        |> update_conflict_hints(key, values)
    end
  end

  @spec update_field(t(), String.t(), [String.t()]) :: t()
  defp update_field(metadata, key, values) do
    cond do
      MapSet.member?(@service_keys, key) and values != [] ->
        %{metadata | service: List.last(values)}

      MapSet.member?(@path_keys, key) and values != [] ->
        %{metadata | paths: Enum.uniq(metadata.paths ++ values)}

      MapSet.member?(@release_keys, key) and values != [] ->
        %{metadata | release: List.last(values)}

      true ->
        metadata
    end
  end

  @spec update_conflict_hints(t(), String.t(), [String.t()]) :: t()
  defp update_conflict_hints(metadata, key, values) do
    prefix = Map.get(@conflict_hint_prefixes, key, :ignore)

    conflict_hints =
      case prefix do
        :ignore -> []
        nil -> values
        value -> Enum.map(values, &(value <> &1))
      end

    %{metadata | conflict_hints: Enum.uniq(metadata.conflict_hints ++ conflict_hints)}
  end

  @spec finalize(t()) :: t()
  defp finalize(metadata) do
    missing_required_fields =
      []
      |> maybe_mark_missing(:service, blank?(metadata.service))
      |> maybe_mark_missing(:paths, metadata.paths == [])

    %{metadata | missing_required_fields: missing_required_fields}
  end

  @spec maybe_mark_missing([atom()], atom(), boolean()) :: [atom()]
  defp maybe_mark_missing(fields, _field, false), do: fields
  defp maybe_mark_missing(fields, field, true), do: fields ++ [field]

  @spec parse_values(String.t()) :: [String.t()]
  defp parse_values(value) do
    value
    |> String.split([",", " "], trim: true)
    |> Enum.map(&normalize_value/1)
    |> Enum.reject(&(&1 == ""))
  end

  @spec normalize_value(term()) :: String.t()
  defp normalize_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(value), do: value in [nil, ""]
end
