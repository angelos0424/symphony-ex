defmodule SymphonyEx.Linear.Client do
  @moduledoc """
  Minimal Linear GraphQL client built on Req.
  """

  require Logger

  alias SymphonyEx.{Observability, Telemetry}

  @default_endpoint "https://api.linear.app/graphql"

  @type issue_map :: map()
  @type comment_map :: map()
  @type workflow_state_map :: map()
  @type request_fun :: (Req.Request.t() -> {:ok, Req.Response.t()} | {:error, term()})

  @spec fetch_candidate_issues(keyword()) :: {:ok, [issue_map()]} | {:error, term()}
  def fetch_candidate_issues(opts) do
    team_key = Keyword.fetch!(opts, :team_key)
    active_states = Keyword.get(opts, :active_states, ["In Progress", "Todo"])
    identifiers = Keyword.get(opts, :include_issue_identifiers, [])

    variables = %{
      "teamKey" => team_key,
      "stateNames" => active_states,
      "identifiers" => identifiers
    }

    query = """
    query CandidateIssues($teamKey: String!, $stateNames: [String!], $identifiers: [String!]) {
      issues(
        filter: {
          team: { key: { eq: $teamKey } }
          state: { name: { in: $stateNames } }
          identifier: { in: $identifiers }
        }
      ) {
        nodes {
          id
          identifier
          title
          description
          url
          priority
          labels { nodes { name } }
          parent { id }
          children { nodes { id } }
          state { id name type }
          assignee { id name email }
          team { id key name }
          updatedAt
        }
      }
    }
    """

    query = maybe_relax_identifier_filter(query, identifiers)
    graphql(query, variables, opts, ["issues", "nodes"])
  end

  @spec fetch_issue_by_identifier(String.t(), keyword()) ::
          {:ok, issue_map() | nil} | {:error, term()}
  def fetch_issue_by_identifier(identifier, opts) do
    query = """
    query IssueByIdentifier($identifier: String!) {
      issue(id: $identifier) {
        id
        identifier
        title
        description
        url
        priority
        labels { nodes { name } }
        parent { id }
        children { nodes { id } }
        state { id name type }
        assignee { id name email }
        team { id key name }
        updatedAt
      }
    }
    """

    case graphql(query, %{"identifier" => identifier}, opts, ["issue"]) do
      {:ok, nil} -> {:ok, nil}
      {:ok, issue} -> {:ok, issue}
      {:error, _} = error -> error
    end
  end

  @spec fetch_issue_workflow_states(String.t(), keyword()) ::
          {:ok, [workflow_state_map()]} | {:error, term()}
  def fetch_issue_workflow_states(issue_id, opts) do
    query = """
    query IssueWorkflowStates($issueId: String!) {
      issue(id: $issueId) {
        team {
          states {
            nodes {
              id
              name
              type
            }
          }
        }
      }
    }
    """

    graphql(query, %{"issueId" => issue_id}, opts, ["issue", "team", "states", "nodes"])
  end

  @spec fetch_issue_comments(String.t(), keyword()) :: {:ok, [comment_map()]} | {:error, term()}
  def fetch_issue_comments(issue_id, opts) do
    query = """
    query IssueComments($issueId: String!) {
      comments(filter: { issue: { id: { eq: $issueId } } }) {
        nodes {
          id
          body
          createdAt
          user { id name }
        }
      }
    }
    """

    graphql(query, %{"issueId" => issue_id}, opts, ["comments", "nodes"])
  end

  @spec create_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_comment(issue_id, body, opts) do
    query = """
    mutation CreateComment($issueId: String!, $body: String!) {
      commentCreate(input: { issueId: $issueId, body: $body }) {
        success
        comment { id body }
      }
    }
    """

    graphql(query, %{"issueId" => issue_id, "body" => body}, opts, ["commentCreate"])
  end

  @spec update_issue_state(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_issue_state(issue_id, state_id, opts) do
    query = """
    mutation UpdateIssueState($issueId: String!, $stateId: String!) {
      issueUpdate(id: $issueId, input: { stateId: $stateId }) {
        success
        issue { id }
      }
    }
    """

    graphql(query, %{"issueId" => issue_id, "stateId" => state_id}, opts, ["issueUpdate"])
  end

  @spec update_issue_description(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_description(issue_id, description, opts) do
    query = """
    mutation UpdateIssueDescription($issueId: String!, $description: String!) {
      issueUpdate(id: $issueId, input: { description: $description }) {
        success
        issue { id description }
      }
    }
    """

    graphql(query, %{"issueId" => issue_id, "description" => description}, opts, ["issueUpdate"])
  end

  @spec graphql(String.t(), map(), keyword(), [String.t()]) :: {:ok, term()} | {:error, term()}
  defp graphql(query, variables, opts, data_path) do
    request_fun = Keyword.get(opts, :request_fun, &Req.request/1)
    endpoint = Keyword.get(opts, :endpoint, @default_endpoint)
    api_key = Keyword.fetch!(opts, :api_key)

    request =
      Req.new(
        url: endpoint,
        method: :post,
        headers: [{"authorization", api_key}],
        json: %{"query" => query, "variables" => variables}
      )

    with {:ok, response} <- request_fun.(request) do
      log_rate_limit(response.headers)

      with {:ok, body} <- normalize_body(response.body),
           :ok <- ensure_no_graphql_errors(body) do
        {:ok, get_in(body, ["data" | data_path])}
      end
    end
  end

  @spec normalize_body(term()) :: {:ok, map()} | {:error, term()}
  defp normalize_body(body) when is_map(body), do: {:ok, body}
  defp normalize_body(body), do: {:error, {:unexpected_body, body}}

  @spec ensure_no_graphql_errors(map()) :: :ok | {:error, term()}
  defp ensure_no_graphql_errors(%{"errors" => [_ | _] = errors}),
    do: {:error, {:graphql_errors, errors}}

  defp ensure_no_graphql_errors(_body), do: :ok

  @spec log_rate_limit(%{optional(String.t()) => [String.t()]}) :: :ok
  defp log_rate_limit(headers) do
    remaining = get_header(headers, "x-ratelimit-remaining")
    limit = get_header(headers, "x-ratelimit-limit")
    reset = get_header(headers, "x-ratelimit-reset")
    retry_after = get_header(headers, "retry-after")
    remaining_int = parse_integer(remaining)
    limit_int = parse_integer(limit)
    reset_at = reset_at_iso8601(reset)
    retry_after_int = parse_integer(retry_after)

    Observability.record_rate_limit(:linear, %{
      remaining: remaining_int,
      limit: limit_int,
      reset: reset,
      retry_after: retry_after_int
    })

    Telemetry.emit_rate_limit(:linear, remaining_int, limit_int, reset_at, retry_after_int)

    case Integer.parse(remaining || "") do
      {remaining_int, _} when remaining_int < 100 ->
        Logger.warning("Linear API rate limit low",
          rate_limit_remaining: remaining,
          rate_limit_limit: limit,
          rate_limit_reset: reset,
          retry_after: retry_after
        )

      {_remaining_int, _} ->
        Logger.debug("Linear API rate limit status",
          rate_limit_remaining: remaining,
          rate_limit_limit: limit,
          rate_limit_reset: reset,
          retry_after: retry_after
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

  @spec maybe_relax_identifier_filter(String.t(), [String.t()]) :: String.t()
  defp maybe_relax_identifier_filter(query, []),
    do: String.replace(query, "identifier: { in: $identifiers }", "")

  defp maybe_relax_identifier_filter(query, _identifiers), do: query
end
