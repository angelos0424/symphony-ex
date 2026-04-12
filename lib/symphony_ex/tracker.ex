defmodule SymphonyEx.Tracker do
  @moduledoc """
  Tracker adapter behaviour used by the orchestrator.
  """

  alias SymphonyEx.Domain.Issue

  @type option :: term()
  @type issue_identifier :: String.t()
  @type desired_state :: atom() | String.t()
  @type comment_body :: String.t()
  @type result(t) :: {:ok, t} | {:error, term()}

  @callback fetch_candidate_issues(keyword()) :: result([Issue.t()])
  @callback fetch_issue_by_identifier(issue_identifier(), keyword()) :: result(Issue.t() | nil)
  @callback fetch_issue_comments(String.t(), keyword()) :: result([map()])
  @callback create_comment(String.t(), comment_body(), keyword()) :: result(map())
  @callback update_issue_state(Issue.t(), desired_state(), keyword()) :: result(map())
  @callback update_issue_description(String.t(), String.t(), keyword()) :: result(map())
  @callback write_run_record(Issue.t(), map(), keyword()) :: result(map())
end
