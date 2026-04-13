defmodule SymphonyEx.GitHub.Client do
  @moduledoc """
  Minimal GitHub client built on Req.

  Uses REST for issue operations and GraphQL for Project v2 reads/writes.
  """

  require Logger

  alias SymphonyEx.{Observability, Telemetry}

  @default_endpoint "https://api.github.com"
  @default_graphql_endpoint "https://api.github.com/graphql"
  @default_headers [
    {"accept", "application/vnd.github+json"},
    {"x-github-api-version", "2022-11-28"}
  ]

  @type issue_map :: map()
  @type comment_map :: map()
  @type project_item_map :: map()
  @type request_fun :: (Req.Request.t() -> {:ok, Req.Response.t()} | {:error, term()})

  @spec fetch_candidate_issues(keyword()) :: {:ok, [issue_map()]} | {:error, term()}
  def fetch_candidate_issues(opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    identifiers = Keyword.get(opts, :include_issue_identifiers, [])

    with {:ok, issues} <-
           rest(:get, "/repos/#{owner}/#{repo}/issues", opts, params: [state: "open"]) do
      issues
      |> Enum.reject(&pull_request?/1)
      |> maybe_filter_issue_identifiers(identifiers)
      |> then(&{:ok, &1})
    end
  end

  @spec fetch_issue(String.t() | pos_integer(), keyword()) ::
          {:ok, issue_map() | nil} | {:error, term()}
  def fetch_issue(number_or_identifier, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    case rest(:get, "/repos/#{owner}/#{repo}/issues/#{issue_number}", opts) do
      {:ok, %{"message" => "Not Found"}} -> {:ok, nil}
      {:ok, issue} -> {:ok, issue}
      {:error, {:http_error, 404, _body}} -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  @spec fetch_issue_comments(String.t() | pos_integer(), keyword()) ::
          {:ok, [comment_map()]} | {:error, term()}
  def fetch_issue_comments(number_or_identifier, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    rest(:get, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", opts)
  end

  @spec create_issue_comment(String.t() | pos_integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def create_issue_comment(number_or_identifier, body, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    rest(:post, "/repos/#{owner}/#{repo}/issues/#{issue_number}/comments", opts,
      json: %{body: body}
    )
  end

  @spec update_issue_body(String.t() | pos_integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_body(number_or_identifier, body, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    rest(:patch, "/repos/#{owner}/#{repo}/issues/#{issue_number}", opts, json: %{body: body})
  end

  @spec update_issue_state(String.t() | pos_integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_state(number_or_identifier, state, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    rest(:patch, "/repos/#{owner}/#{repo}/issues/#{issue_number}", opts, json: %{state: state})
  end

  @spec assign_issue(String.t() | pos_integer(), [String.t()], keyword()) ::
          {:ok, map()} | {:error, term()}
  def assign_issue(number_or_identifier, assignees, opts) when is_list(assignees) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    rest(:patch, "/repos/#{owner}/#{repo}/issues/#{issue_number}", opts,
      json: %{assignees: assignees}
    )
  end

  @spec add_labels(String.t() | pos_integer(), [String.t()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def add_labels(number_or_identifier, labels, opts) when is_list(labels) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)

    rest(:post, "/repos/#{owner}/#{repo}/issues/#{issue_number}/labels", opts,
      json: %{labels: labels}
    )
  end

  @spec remove_label(String.t() | pos_integer(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def remove_label(number_or_identifier, label, opts) do
    owner = Keyword.fetch!(opts, :owner)
    repo = Keyword.fetch!(opts, :repo)
    issue_number = normalize_issue_number(number_or_identifier)
    encoded_label = URI.encode(label)

    rest(:delete, "/repos/#{owner}/#{repo}/issues/#{issue_number}/labels/#{encoded_label}", opts)
  end

  @spec list_project_items(keyword()) :: {:ok, [project_item_map()]} | {:error, term()}
  def list_project_items(opts) do
    owner = Keyword.fetch!(opts, :owner)
    project_number = Keyword.fetch!(opts, :project_number)
    include_issue_body = Keyword.get(opts, :include_issue_body, true)

    query = project_items_query(include_issue_body)

    variables = %{"owner" => owner, "number" => project_number}

    with {:ok, data} <- graphql(query, variables, opts),
         {:ok, project} <- extract_project(data, owner) do
      project_fields =
        project
        |> get_in(["fields", "nodes"])
        |> List.wrap()

      items =
        project
        |> get_in(["items", "nodes"])
        |> List.wrap()
        |> Enum.map(fn item ->
          item
          |> Map.put("projectId", project["id"])
          |> Map.put("projectFields", project_fields)
        end)

      {:ok, items}
    end
  end

  @spec project_items_query(boolean()) :: String.t()
  defp project_items_query(include_issue_body) do
    issue_body_field =
      if include_issue_body do
        """
                  body
        """
      else
        ""
      end

    """
    query ProjectItems($owner: String!, $number: Int!) {
      organization(login: $owner) {
        projectV2(number: $number) {
          id
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon {
                id
                name
              }
              ... on ProjectV2SingleSelectField {
                id
                name
                options {
                  id
                  name
                }
              }
              ... on ProjectV2IterationField {
                id
                name
                configuration {
                  iterations {
                    id
                    title
                  }
                }
              }
            }
          }
          items(first: 100) {
            nodes {
              id
              fieldValues(first: 50) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                      ... on ProjectV2SingleSelectField {
                        id
                        name
                        options {
                          id
                          name
                        }
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldTextValue {
                    text
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldNumberValue {
                    number
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldDateValue {
                    date
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldIterationValue {
                    title
                    iterationId
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                      ... on ProjectV2IterationField {
                        id
                        name
                        configuration {
                          iterations {
                            id
                            title
                          }
                        }
                      }
                    }
                  }
                }
              }
              content {
                ... on Issue {
                  id
                  number
                  title
                  state
    #{issue_body_field}              url
                }
              }
            }
          }
        }
      }
      user(login: $owner) {
        projectV2(number: $number) {
          id
          fields(first: 50) {
            nodes {
              ... on ProjectV2FieldCommon {
                id
                name
              }
              ... on ProjectV2SingleSelectField {
                id
                name
                options {
                  id
                  name
                }
              }
              ... on ProjectV2IterationField {
                id
                name
                configuration {
                  iterations {
                    id
                    title
                  }
                }
              }
            }
          }
          items(first: 100) {
            nodes {
              id
              fieldValues(first: 50) {
                nodes {
                  ... on ProjectV2ItemFieldSingleSelectValue {
                    name
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                      ... on ProjectV2SingleSelectField {
                        id
                        name
                        options {
                          id
                          name
                        }
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldTextValue {
                    text
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldNumberValue {
                    number
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldDateValue {
                    date
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                    }
                  }
                  ... on ProjectV2ItemFieldIterationValue {
                    title
                    iterationId
                    field {
                      ... on ProjectV2FieldCommon {
                        id
                        name
                      }
                      ... on ProjectV2IterationField {
                        id
                        name
                        configuration {
                          iterations {
                            id
                            title
                          }
                        }
                      }
                    }
                  }
                }
              }
              content {
                ... on Issue {
                  id
                  number
                  title
                  state
    #{issue_body_field}              url
                }
              }
            }
          }
        }
      }
    }
    """
  end

  @spec update_project_status(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_project_status(project_id, item_id, field_id, single_select_option_id, opts) do
    update_project_field_value(
      project_id,
      item_id,
      field_id,
      %{single_select_option_id: single_select_option_id},
      opts,
      mutation_name: "UpdateProjectStatus"
    )
  end

  @spec update_project_field_value(
          String.t(),
          String.t(),
          String.t(),
          map(),
          keyword(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()}
  def update_project_field_value(project_id, item_id, field_id, value, opts, mutation_opts \\ [])

  def update_project_field_value(
        project_id,
        item_id,
        field_id,
        %{single_select_option_id: option_id},
        opts,
        mutation_opts
      ) do
    mutation_name = Keyword.get(mutation_opts, :mutation_name, "UpdateProjectFieldValue")

    mutation = """
    mutation #{mutation_name}($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { singleSelectOptionId: $optionId }
        }
      ) {
        projectV2Item {
          id
        }
      }
    }
    """

    graphql(
      mutation,
      %{
        "projectId" => project_id,
        "itemId" => item_id,
        "fieldId" => field_id,
        "optionId" => option_id
      },
      opts
    )
  end

  def update_project_field_value(
        project_id,
        item_id,
        field_id,
        %{text: text},
        opts,
        mutation_opts
      ) do
    mutation_name = Keyword.get(mutation_opts, :mutation_name, "UpdateProjectFieldValue")

    mutation = """
    mutation #{mutation_name}($projectId: ID!, $itemId: ID!, $fieldId: ID!, $text: String!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { text: $text }
        }
      ) {
        projectV2Item {
          id
        }
      }
    }
    """

    graphql(
      mutation,
      %{
        "projectId" => project_id,
        "itemId" => item_id,
        "fieldId" => field_id,
        "text" => text
      },
      opts
    )
  end

  def update_project_field_value(
        project_id,
        item_id,
        field_id,
        %{number: number},
        opts,
        mutation_opts
      ) do
    mutation_name = Keyword.get(mutation_opts, :mutation_name, "UpdateProjectFieldValue")

    mutation = """
    mutation #{mutation_name}($projectId: ID!, $itemId: ID!, $fieldId: ID!, $number: Float!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { number: $number }
        }
      ) {
        projectV2Item {
          id
        }
      }
    }
    """

    graphql(
      mutation,
      %{
        "projectId" => project_id,
        "itemId" => item_id,
        "fieldId" => field_id,
        "number" => number * 1.0
      },
      opts
    )
  end

  def update_project_field_value(
        project_id,
        item_id,
        field_id,
        %{date: date},
        opts,
        mutation_opts
      ) do
    mutation_name = Keyword.get(mutation_opts, :mutation_name, "UpdateProjectFieldValue")

    mutation = """
    mutation #{mutation_name}($projectId: ID!, $itemId: ID!, $fieldId: ID!, $date: Date!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { date: $date }
        }
      ) {
        projectV2Item {
          id
        }
      }
    }
    """

    graphql(
      mutation,
      %{
        "projectId" => project_id,
        "itemId" => item_id,
        "fieldId" => field_id,
        "date" => date
      },
      opts
    )
  end

  def update_project_field_value(
        project_id,
        item_id,
        field_id,
        %{iteration_id: iteration_id},
        opts,
        mutation_opts
      ) do
    mutation_name = Keyword.get(mutation_opts, :mutation_name, "UpdateProjectFieldValue")

    mutation = """
    mutation #{mutation_name}($projectId: ID!, $itemId: ID!, $fieldId: ID!, $iterationId: String!) {
      updateProjectV2ItemFieldValue(
        input: {
          projectId: $projectId
          itemId: $itemId
          fieldId: $fieldId
          value: { iterationId: $iterationId }
        }
      ) {
        projectV2Item {
          id
        }
      }
    }
    """

    graphql(
      mutation,
      %{
        "projectId" => project_id,
        "itemId" => item_id,
        "fieldId" => field_id,
        "iterationId" => iteration_id
      },
      opts
    )
  end

  @spec graphql(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def graphql(query, variables, opts) do
    endpoint = Keyword.get(opts, :graphql_endpoint, @default_graphql_endpoint)

    request(:post, endpoint, opts,
      headers: @default_headers,
      json: %{"query" => query, "variables" => variables}
    )
    |> case do
      {:ok, body} ->
        case body do
          %{"errors" => [_ | _] = errors} -> {:error, {:graphql_errors, errors}}
          %{"data" => data} when is_map(data) -> {:ok, data}
          other -> {:error, {:unexpected_body, other}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  @spec rest(atom(), String.t(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp rest(method, path, opts, request_opts \\ []) do
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    request(method, endpoint <> path, opts, Keyword.put(request_opts, :headers, @default_headers))
  end

  @spec request(atom(), String.t(), keyword(), keyword()) :: {:ok, term()} | {:error, term()}
  defp request(method, url, opts, request_opts) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    api_key = Keyword.fetch!(opts, :api_key)
    headers = Keyword.get(request_opts, :headers, []) ++ [{"authorization", "Bearer #{api_key}"}]

    request =
      Req.new(
        url: url,
        method: method,
        headers: headers,
        params: Keyword.get(request_opts, :params, []),
        json: Keyword.get(request_opts, :json)
      )

    with {:ok, response} <- request_fun.(request) do
      log_rate_limit(response.headers)

      with {:ok, body} <- normalize_body(response.body),
           :ok <- ensure_success(response.status, body) do
        {:ok, body}
      end
    end
  end

  @spec normalize_body(term()) :: {:ok, term()} | {:error, term()}
  defp normalize_body(body) when is_map(body) or is_list(body), do: {:ok, body}
  defp normalize_body(body), do: {:error, {:unexpected_body, body}}

  @spec ensure_success(pos_integer(), term()) :: :ok | {:error, term()}
  defp ensure_success(status, _body) when status in 200..299, do: :ok
  defp ensure_success(status, body), do: {:error, {:http_error, status, body}}

  @spec pull_request?(map()) :: boolean()
  defp pull_request?(%{"pull_request" => %{} = _pr}), do: true
  defp pull_request?(_issue), do: false

  @spec maybe_filter_issue_identifiers([issue_map()], [String.t()]) :: [issue_map()]
  defp maybe_filter_issue_identifiers(issues, []), do: issues

  defp maybe_filter_issue_identifiers(issues, identifiers) do
    wanted = MapSet.new(Enum.map(identifiers, &normalize_issue_number/1))
    Enum.filter(issues, &MapSet.member?(wanted, normalize_issue_number(&1["number"])))
  end

  @spec normalize_issue_number(String.t() | integer()) :: integer()
  defp normalize_issue_number(number) when is_integer(number), do: number

  defp normalize_issue_number(identifier) when is_binary(identifier) do
    identifier
    |> String.trim()
    |> String.split("#")
    |> List.last()
    |> String.to_integer()
  end

  @spec log_rate_limit(%{optional(String.t()) => [String.t()]}) :: :ok
  defp log_rate_limit(headers) do
    remaining = get_header(headers, "x-ratelimit-remaining")
    limit = get_header(headers, "x-ratelimit-limit")
    reset = get_header(headers, "x-ratelimit-reset")

    remaining_int = parse_integer(remaining)
    limit_int = parse_integer(limit)
    reset_at = reset_at_iso8601(reset)

    Observability.record_rate_limit(:github, %{
      remaining: remaining_int,
      limit: limit_int,
      reset: reset
    })

    Telemetry.emit_rate_limit(:github, remaining_int, limit_int, reset_at, nil)

    case Integer.parse(remaining || "") do
      {remaining_int, _} when remaining_int < 100 ->
        Logger.warning("GitHub API rate limit low",
          rate_limit_remaining: remaining,
          rate_limit_limit: limit,
          rate_limit_reset: reset
        )

      {_remaining_int, _} ->
        Logger.debug("GitHub API rate limit status",
          rate_limit_remaining: remaining,
          rate_limit_limit: limit,
          rate_limit_reset: reset
        )

      _ ->
        :ok
    end
  end

  defp get_header(headers, name) when is_map(headers) do
    case Map.get(headers, name) do
      [value | _] -> value
      _ -> nil
    end
  end

  defp get_header(headers, name) when is_list(headers) do
    case List.keyfind(headers, name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp get_header(_, _), do: nil

  defp parse_integer(nil), do: nil

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> nil
    end
  end

  defp parse_integer(value) when is_integer(value), do: value
  defp parse_integer(_value), do: nil

  defp reset_at_iso8601(nil), do: nil

  defp reset_at_iso8601(value) do
    case parse_integer(value) do
      nil -> nil
      unix -> unix |> DateTime.from_unix!() |> DateTime.to_iso8601()
    end
  end

  @spec extract_project(map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp extract_project(data, owner) do
    cond do
      is_map(get_in(data, ["organization", "projectV2"])) ->
        {:ok, get_in(data, ["organization", "projectV2"])}

      is_map(get_in(data, ["user", "projectV2"])) ->
        {:ok, get_in(data, ["user", "projectV2"])}

      true ->
        {:error, {:project_not_found, owner}}
    end
  end
end
