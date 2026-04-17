defmodule SymphonyEx.WorkflowEditor do
  @moduledoc """
  Small helper for updating selected WORKFLOW.md front matter settings in place.

  The editor is intentionally narrow: it only upserts scalar keys under known
  top-level sections and leaves the template body untouched.
  """

  @type orchestrator_updates :: %{
          optional(:poll_interval_ms) => pos_integer(),
          optional(:max_concurrent) => pos_integer(),
          optional(:max_retries) => non_neg_integer(),
          optional(:backoff_base_ms) => pos_integer()
        }

  @orchestrator_key_map %{
    poll_interval_ms: "poll-interval-ms",
    max_concurrent: "max-concurrent",
    max_retries: "max-retries",
    backoff_base_ms: "backoff-base-ms"
  }

  @spec update_orchestrator_settings(String.t(), orchestrator_updates()) ::
          {:ok, String.t()} | {:error, term()}
  def update_orchestrator_settings(workflow_path, updates) when is_map(updates) do
    with {:ok, content} <- File.read(workflow_path),
         {:ok, yaml, body} <- split_front_matter(content),
         updated_yaml <- apply_orchestrator_updates(yaml, updates),
         :ok <- File.write(workflow_path, build_content(updated_yaml, body)) do
      {:ok, workflow_path}
    end
  end

  @spec split_front_matter(String.t()) :: {:ok, String.t(), String.t()} | {:error, term()}
  defp split_front_matter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)\z/s, content) do
      [_, yaml, body] -> {:ok, yaml, body}
      nil -> {:error, :missing_front_matter}
    end
  end

  @spec apply_orchestrator_updates(String.t(), orchestrator_updates()) :: String.t()
  defp apply_orchestrator_updates(yaml, updates) do
    Enum.reduce(updates, yaml, fn
      {_key, nil}, acc ->
        acc

      {key, value}, acc ->
        upsert_section_scalar(acc, "orchestrator", Map.fetch!(@orchestrator_key_map, key), value)
    end)
  end

  @spec upsert_section_scalar(String.t(), String.t(), String.t(), term()) :: String.t()
  defp upsert_section_scalar(yaml, section, key, value) do
    lines = String.split(yaml, "\n", trim: false)
    section_header = "#{section}:"
    section_index = Enum.find_index(lines, &(&1 == section_header))

    case section_index do
      nil ->
        append_new_section(lines, section_header, key, value)

      index ->
        update_existing_section(lines, index, key, value)
    end
    |> Enum.join("\n")
  end

  @spec append_new_section([String.t()], String.t(), String.t(), term()) :: [String.t()]
  defp append_new_section(lines, section_header, key, value) do
    trimmed = trim_trailing_blank_lines(lines)

    trimmed ++
      blank_separator(trimmed) ++
      [section_header, "  #{key}: #{yaml_scalar(value)}"]
  end

  @spec update_existing_section([String.t()], non_neg_integer(), String.t(), term()) :: [
          String.t()
        ]
  defp update_existing_section(lines, section_index, key, value) do
    section_end = find_section_end(lines, section_index + 1)
    {prefix, rest} = Enum.split(lines, section_index + 1)
    {section_lines, suffix} = Enum.split(rest, section_end - (section_index + 1))

    updated_section_lines =
      case Enum.find_index(section_lines, &String.starts_with?(&1, "  #{key}:")) do
        nil -> section_lines ++ ["  #{key}: #{yaml_scalar(value)}"]
        index -> List.replace_at(section_lines, index, "  #{key}: #{yaml_scalar(value)}")
      end

    prefix ++ updated_section_lines ++ suffix
  end

  @spec find_section_end([String.t()], non_neg_integer()) :: non_neg_integer()
  defp find_section_end(lines, start_index) do
    lines
    |> Enum.with_index()
    |> Enum.find_value(length(lines), fn {line, index} ->
      if index >= start_index and top_level_section_line?(line), do: index, else: nil
    end)
  end

  @spec top_level_section_line?(String.t()) :: boolean()
  defp top_level_section_line?(line) do
    line != "" and not String.starts_with?(line, " ") and String.ends_with?(line, ":")
  end

  @spec trim_trailing_blank_lines([String.t()]) :: [String.t()]
  defp trim_trailing_blank_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  @spec blank_separator([String.t()]) :: [String.t()]
  defp blank_separator([]), do: []
  defp blank_separator(_lines), do: [""]

  @spec yaml_scalar(term()) :: String.t()
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_boolean(value), do: to_string(value)
  defp yaml_scalar(value) when is_binary(value), do: value

  @spec build_content(String.t(), String.t()) :: String.t()
  defp build_content(yaml, body), do: "---\n#{yaml}\n---\n#{body}"
end
