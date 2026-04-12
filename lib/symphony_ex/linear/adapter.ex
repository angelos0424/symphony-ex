defmodule SymphonyEx.Linear.Adapter do
  @moduledoc """
  Linear-backed tracker adapter.
  """

  @behaviour SymphonyEx.Tracker

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.Linear.Client

  @managed_start "<!-- symphony:managed -->"
  @managed_end "<!-- /symphony:managed -->"

  @desired_state_aliases %{
    "todo" => ["Todo", "Backlog", "Triage"],
    "in_progress" => ["In Progress", "Started", "Doing"],
    "done" => ["Done", "Completed", "Canceled", "Cancelled"]
  }

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts) do
    with {:ok, issues} <- Client.fetch_candidate_issues(opts) do
      {:ok, Enum.map(issues, &to_issue/1)}
    end
  end

  @spec fetch_issue_by_identifier(String.t(), keyword()) ::
          {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(identifier, opts) do
    with {:ok, issue} <- Client.fetch_issue_by_identifier(identifier, opts) do
      {:ok, if(issue, do: to_issue(issue), else: nil)}
    end
  end

  @spec fetch_issue_comments(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(issue_id, opts), do: Client.fetch_issue_comments(issue_id, opts)

  @spec create_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_comment(issue_id, body, opts), do: Client.create_comment(issue_id, body, opts)

  @spec update_issue_state(Issue.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_state(%Issue{} = issue, desired_state, opts) do
    with {:ok, state} <- resolve_issue_state(issue, desired_state, opts) do
      Client.update_issue_state(issue.id, state["id"], opts)
    end
  end

  @spec resolve_issue_state(Issue.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def resolve_issue_state(%Issue{} = issue, desired_state, opts) do
    with {:ok, workflow_states} <- Client.fetch_issue_workflow_states(issue.id, opts),
         {:ok, canonical_name} <- normalize_desired_state(desired_state) do
      aliases = desired_state_aliases(opts)

      case Enum.find(workflow_states, &workflow_state_matches?(&1, canonical_name, aliases)) do
        nil ->
          {:error,
           {:state_not_found,
            %{
              desired_state: canonical_name,
              available_states: Enum.map(workflow_states, & &1["name"])
            }}}

        state ->
          {:ok, state}
      end
    end
  end

  @spec resolve_issue_state_id(Issue.t(), atom() | String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def resolve_issue_state_id(%Issue{} = issue, desired_state, opts) do
    with {:ok, state} <- resolve_issue_state(issue, desired_state, opts) do
      {:ok, state["id"]}
    end
  end

  @spec update_issue_description(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_description(issue_id, description, opts),
    do: Client.update_issue_description(issue_id, description, opts)

  @spec write_run_record(Issue.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write_run_record(%Issue{} = issue, attrs, opts) do
    body = render_run_record(issue, attrs)
    description = upsert_managed_working_record(issue.description || "", body)
    update_issue_description(issue.id, description, opts)
  end

  @spec to_issue(map()) :: Issue.t()
  def to_issue(issue) do
    %Issue{
      id: issue["id"],
      identifier: issue["identifier"],
      title: issue["title"] || "",
      description: issue["description"] || "",
      url: issue["url"],
      state: get_in(issue, ["state", "name"]) || "",
      priority: issue["priority"] || 0,
      labels: get_in(issue, ["labels", "nodes"]) |> extract_names(),
      parent_id: get_in(issue, ["parent", "id"]),
      children_ids: get_in(issue, ["children", "nodes"]) |> extract_ids()
    }
  end

  @spec render_run_record(Issue.t(), map()) :: String.t()
  def render_run_record(%Issue{} = issue, attrs) do
    attrs = Map.new(attrs)

    lines = [
      "issue: #{issue.identifier}",
      "status: #{Map.fetch!(attrs, :status)}",
      "attempt: #{Map.fetch!(attrs, :attempt)}",
      "updated_at: #{DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()}"
    ]

    extra_lines =
      attrs
      |> Map.drop([:status, :attempt])
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} -> "#{key}: #{format_metadata_value(value)}" end)

    Enum.join(lines ++ extra_lines, "\n")
  end

  @spec managed_block(String.t()) :: String.t()
  def managed_block(body) do
    Enum.join([@managed_start, body, @managed_end], "\n")
  end

  @spec upsert_managed_working_record(String.t(), String.t()) :: String.t()
  def upsert_managed_working_record(description, body) do
    block = managed_block(body)
    regex = ~r/<!-- symphony:managed -->.*?<!-- \/symphony:managed -->/s

    cond do
      description =~ regex -> String.replace(description, regex, block)
      String.trim(description) == "" -> block
      true -> String.trim_trailing(description) <> "\n\n" <> block
    end
  end

  @spec desired_state_aliases(keyword()) :: %{String.t() => [String.t()]}
  defp desired_state_aliases(opts) do
    opts
    |> Keyword.get(:desired_state_aliases, %{})
    |> Enum.into(@desired_state_aliases, fn {key, names} -> {normalize_key(key), names} end)
  end

  @spec normalize_desired_state(atom() | String.t()) :: {:ok, String.t()} | {:error, term()}
  defp normalize_desired_state(state) when is_atom(state), do: {:ok, normalize_key(state)}

  defp normalize_desired_state(state) when is_binary(state) do
    normalized = normalize_key(state)

    if normalized == "" do
      {:error, {:invalid_desired_state, state}}
    else
      {:ok, normalized}
    end
  end

  defp workflow_state_matches?(workflow_state, desired_state, aliases) do
    candidate_names = Map.get(aliases, desired_state, [desired_state])
    normalized_name = normalize_key(workflow_state["name"] || "")
    normalized_type = normalize_key(workflow_state["type"] || "")

    normalized_name == desired_state or normalized_type == desired_state or
      Enum.any?(candidate_names, &(normalize_key(&1) == normalized_name))
  end

  defp normalize_key(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  @spec format_metadata_value(term()) :: String.t()
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value), do: inspect(value)

  @spec extract_names(nil | [map()]) :: [String.t()]
  defp extract_names(nil), do: []
  defp extract_names(nodes), do: Enum.map(nodes, & &1["name"])

  @spec extract_ids(nil | [map()]) :: [String.t()]
  defp extract_ids(nil), do: []
  defp extract_ids(nodes), do: Enum.map(nodes, & &1["id"])
end
