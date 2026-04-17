defmodule SymphonyEx.GitHub.IssueBodyMetadata do
  @moduledoc """
  Parses structured GitHub issue body metadata used for dispatch eligibility.
  """

  @type t :: %__MODULE__{
          service: String.t() | nil,
          paths: [String.t()],
          release: String.t() | nil,
          conflict_hints: [String.t()],
          missing_required_fields: [atom()],
          target_branch: String.t() | nil,
          target_pr: pos_integer() | nil
        }

  defstruct service: nil,
            paths: [],
            release: nil,
            conflict_hints: [],
            missing_required_fields: [],
            target_branch: nil,
            target_pr: nil

  @service_keys MapSet.new(["service", "services"])
  @path_keys MapSet.new(["path", "paths"])
  @release_keys MapSet.new(["release"])
  @target_branch_keys MapSet.new(["target-branch", "target_branch", "branch", "working-branch", "working_branch", "작업 브랜치"])
  @target_pr_keys MapSet.new(["target-pr", "target_pr", "pr", "existing-pr", "existing_pr", "existing pr"])

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
        |> update_field(key, values, raw_values)
        |> update_conflict_hints(key, values)
    end
  end

  @spec update_field(t(), String.t(), [String.t()], String.t()) :: t()
  defp update_field(metadata, key, values, raw_value) do
    cond do
      MapSet.member?(@service_keys, key) and values != [] ->
        %{metadata | service: List.last(values)}

      MapSet.member?(@path_keys, key) and values != [] ->
        %{metadata | paths: Enum.uniq(metadata.paths ++ values)}

      MapSet.member?(@release_keys, key) and values != [] ->
        %{metadata | release: List.last(values)}

      MapSet.member?(@target_branch_keys, key) ->
        case normalize_branch_value(raw_value) do
          nil -> metadata
          branch -> %{metadata | target_branch: branch}
        end

      MapSet.member?(@target_pr_keys, key) ->
        case extract_pr_number(raw_value) do
          nil -> metadata
          pr_number -> %{metadata | target_pr: pr_number}
        end

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

  @spec normalize_branch_value(String.t()) :: String.t() | nil
  defp normalize_branch_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.trim_leading("`")
    |> String.trim_trailing("`")
    |> case do
      "" -> nil
      branch -> branch
    end
  end

  @spec extract_pr_number(String.t()) :: pos_integer() | nil
  defp extract_pr_number(value) do
    value
    |> to_string()
    |> String.trim()
    |> then(fn trimmed ->
      Regex.run(~r/(?:^|\b#|\/pull\/)(\d+)\b/, trimmed, capture: :all_but_first)
    end)
    |> case do
      [value] -> String.to_integer(value)
      _other -> nil
    end
  end

  @spec blank?(String.t() | nil) :: boolean()
  defp blank?(value), do: value in [nil, ""]
end
