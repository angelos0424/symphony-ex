defmodule SymphonyEx.GitHub.Adapter do
  @moduledoc """
  GitHub-backed tracker adapter.
  """

  @behaviour SymphonyEx.Tracker

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.GitHub.Client
  alias SymphonyEx.GitHub.IssueBodyMetadata
  alias SymphonyEx.Observability
  alias SymphonyEx.Orchestrator.Lifecycle
  alias SymphonyEx.Telemetry

  @managed_start "<!-- symphony:managed -->"
  @managed_end "<!-- /symphony:managed -->"
  @status_start "<!-- symphony:status -->"
  @status_end "<!-- /symphony:status -->"

  @spec fetch_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues(opts) do
    if Keyword.has_key?(opts, :project_number) do
      fetch_project_candidate_issues(opts)
    else
      with {:ok, issues} <- Client.fetch_candidate_issues(opts) do
        {:ok, Enum.map(issues, &to_issue(&1, opts))}
      end
    end
  end

  @spec fetch_issue_by_identifier(String.t(), keyword()) ::
          {:ok, Issue.t() | nil} | {:error, term()}
  def fetch_issue_by_identifier(identifier, opts) do
    with {:ok, issue} <- Client.fetch_issue(identifier, opts) do
      case issue do
        nil ->
          {:ok, nil}

        %{} = issue_map ->
          with {:ok, blocked_by_issues} <- Client.fetch_issue_blocked_by(identifier, opts) do
            {:ok,
             to_issue(issue_map,
               opts
               |> Keyword.put(
                 :blocked_by_identifiers,
                 extract_blocked_by_identifiers(blocked_by_issues)
               )
             )}
          end
      end
    end
  end

  @spec fetch_issue_comments(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_issue_comments(identifier, opts), do: Client.fetch_issue_comments(identifier, opts)

  @spec create_comment(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def create_comment(identifier, body, opts),
    do: Client.create_issue_comment(identifier, body, opts)

  @spec update_issue_state(Issue.t(), atom() | String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_state(%Issue{} = issue, desired_state, opts) do
    state = normalize_desired_state(desired_state)

    case state do
      :done -> Client.update_issue_state(issue.identifier, "closed", opts)
      :todo -> Client.update_issue_state(issue.identifier, "open", opts)
      :in_progress -> Client.update_issue_state(issue.identifier, "open", opts)
      :open -> Client.update_issue_state(issue.identifier, "open", opts)
      :closed -> Client.update_issue_state(issue.identifier, "closed", opts)
    end
  end

  @spec update_issue_description(String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_issue_description(identifier, description, opts),
    do: Client.update_issue_body(identifier, description, opts)

  @spec write_run_record(Issue.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def write_run_record(%Issue{} = issue, attrs, opts) do
    body = render_run_record(issue, attrs)
    comment = managed_block(body)

    with {:ok, response} <- create_comment(issue.identifier, comment, opts),
         {:ok, _body_response} <- update_issue_status_summary(issue, attrs, opts) do
      emit_write_back_stage(issue, :managed_record, :success, %{status: Map.get(attrs, :status)})

      case sync_write_back(issue, attrs, opts) do
        :ok ->
          {:ok, response}

        {:ok, {:partial, stage, reason}} ->
          emit_write_back_stage(issue, :optional, :partial, %{
            failed_stage: stage,
            reason: inspect(reason)
          })

          annotate_partial_write_back(issue, attrs, stage, reason, opts)
          {:ok, response}

        {:error, stage, reason} ->
          emit_write_back_stage(issue, :essential, :failed, %{
            failed_stage: stage,
            reason: inspect(reason)
          })

          annotate_partial_write_back(issue, attrs, stage, reason, opts)
          {:error, {:partial_write_back, stage, reason}}
      end
    else
      {:error, reason} ->
        emit_write_back_stage(issue, :managed_record, :failed, %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  @spec to_issue(map(), keyword()) :: Issue.t()
  def to_issue(issue, opts \\ []) do
    metadata = IssueBodyMetadata.parse(issue["body"] || "")
    target_pr = metadata.target_pr
    target_branch = metadata.target_branch || resolve_target_branch_from_pr(target_pr, opts)

    %Issue{
      id: to_string(issue["id"] || issue["node_id"] || issue["number"]),
      identifier: to_string(issue["number"]),
      title: issue["title"] || "",
      description: issue["body"] || "",
      url: issue["html_url"] || issue["url"],
      state: normalize_issue_state(issue),
      priority: 0,
      labels: extract_labels(issue["labels"]),
      assignees: extract_assignees(issue["assignees"]),
      conflict_hints: metadata.conflict_hints,
      missing_required_fields: metadata.missing_required_fields,
      blocked_by_identifiers: Keyword.get(opts, :blocked_by_identifiers, []),
      target_branch: target_branch,
      target_pr: target_pr,
      parent_id: nil,
      children_ids: []
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
  def managed_block(body), do: Enum.join([@managed_start, body, @managed_end], "\n")

  @spec update_issue_status_summary(Issue.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()}
  defp update_issue_status_summary(%Issue{} = issue, attrs, opts) do
    if Map.get(attrs, :status) in [:released] do
      latest_body = latest_issue_description(issue, opts)
      summary = render_issue_status_summary(issue, attrs, opts)
      description = upsert_issue_status_summary(latest_body, summary)
      update_issue_description(issue.identifier, description, opts)
    else
      {:ok, %{"body" => issue.description || ""}}
    end
  end

  @spec render_issue_status_summary(Issue.t(), map(), keyword()) :: String.t()
  defp render_issue_status_summary(%Issue{} = issue, attrs, opts) do
    related_pr = latest_related_pr(issue, attrs, opts)

    pr_line =
      case related_pr do
        nil -> "- Pull request: none"
        pr -> "- Pull request: PR ##{pr["number"]} #{pr["html_url"]}"
      end

    outcome =
      cond do
        Map.get(attrs, :status) == :released and Map.get(attrs, :result) == :success and
            not is_nil(related_pr) ->
          "pr_created"

        Map.get(attrs, :status) == :released and Map.get(attrs, :result) == :success ->
          "in_review"

        Map.get(attrs, :status) == :released and Map.get(attrs, :result) == :failed ->
          "failed"

        true ->
          to_string(Map.get(attrs, :status) || "unknown")
      end

    Enum.join(
      [
        "## Symphony Status",
        "- Final status: #{outcome}",
        "- Attempt: #{Map.get(attrs, :attempt, 0)}",
        pr_line,
        "- Updated at: #{DateTime.utc_now() |> DateTime.to_iso8601()}"
      ],
      "\n"
    )
  end

  @spec latest_related_pr(Issue.t(), map(), keyword()) :: map() | nil
  defp latest_related_pr(%Issue{} = issue, attrs, opts) do
    if Map.get(attrs, :result) == :success do
      case Client.list_pull_requests(opts) do
        {:ok, prs} when is_list(prs) ->
          prs
          |> Enum.filter(&related_pr_matches_issue?(&1, issue))
          |> Enum.sort_by(&(&1["created_at"] || &1["createdAt"] || ""), :desc)
          |> List.first()

        _ ->
          nil
      end
    end
  end

  @spec related_pr_matches_issue?(map(), Issue.t()) :: boolean()
  defp related_pr_matches_issue?(pr, %Issue{} = issue) do
    pr_number = pr["number"]
    head_ref = get_in(pr, ["head", "ref"]) || pr["headRefName"] || ""
    body = pr["body"] || ""
    issue_number = to_string(issue.identifier)

    explicit_target_match? =
      cond do
        is_integer(issue.target_pr) and is_binary(issue.target_branch) ->
          pr_number == issue.target_pr and head_ref == issue.target_branch

        is_integer(issue.target_pr) ->
          pr_number == issue.target_pr

        is_binary(issue.target_branch) and String.trim(issue.target_branch) != "" ->
          head_ref == issue.target_branch

        true ->
          nil
      end

    case explicit_target_match? do
      nil ->
        String.contains?(body, "##{issue_number}") or
          String.contains?(head_ref, "issue-#{issue_number}")

      value ->
        value
    end
  end

  @spec latest_issue_description(Issue.t(), keyword()) :: String.t()
  defp latest_issue_description(%Issue{} = issue, opts) do
    case Client.fetch_issue(issue.identifier, opts) do
      {:ok, %{} = latest_issue} -> latest_issue["body"] || issue.description || ""
      _ -> issue.description || ""
    end
  end

  @spec resolve_target_branch_from_pr(pos_integer() | nil, keyword()) :: String.t() | nil
  defp resolve_target_branch_from_pr(nil, _opts), do: nil

  defp resolve_target_branch_from_pr(pr_number, opts) when is_integer(pr_number) do
    if Enum.all?([:owner, :repo], &Keyword.has_key?(opts, &1)) do
      case Client.fetch_pull_request(pr_number, opts) do
        {:ok, %{} = pr} -> get_in(pr, ["head", "ref"]) || pr["headRefName"]
        _other -> nil
      end
    else
      nil
    end
  end

  @spec upsert_issue_status_summary(String.t(), String.t()) :: String.t()
  defp upsert_issue_status_summary(description, summary) do
    block = Enum.join([@status_start, summary, @status_end], "\n")
    regex = ~r/<!-- symphony:status -->.*?<!-- \/symphony:status -->/s

    cond do
      description =~ regex -> String.replace(description, regex, block)
      String.trim(description) == "" -> block
      true -> String.trim_trailing(description) <> "\n\n" <> block
    end
  end

  @spec fetch_project_candidate_issues(keyword()) :: {:ok, [Issue.t()]} | {:error, term()}
  defp fetch_project_candidate_issues(opts) do
    active_states = Keyword.get(opts, :active_states, ["In Progress", "Todo"])
    identifiers = Keyword.get(opts, :include_issue_identifiers, [])

    with {:ok, items} <- Client.list_project_items(Keyword.put(opts, :include_issue_body, true)) do
      issues =
        items
        |> Enum.filter(&active_project_item?(&1, active_states))
        |> Enum.map(&project_item_to_issue(&1, opts))
        |> Enum.reject(&is_nil/1)
        |> maybe_filter_issue_identifiers(identifiers)

      {:ok, issues}
    end
  end

  @spec project_item_to_issue(map(), keyword()) :: Issue.t() | nil
  defp project_item_to_issue(%{"content" => %{"number" => _number} = issue} = item, opts) do
    issue
    |> Map.put("state", project_item_status(item) || issue["state"])
    |> to_issue(opts)
  end

  defp project_item_to_issue(_item, _opts), do: nil

  @spec active_project_item?(map(), [String.t()]) :: boolean()
  defp active_project_item?(item, active_states) do
    status = project_item_status(item)
    issue = Map.get(item, "content", %{})

    is_map(issue) and is_integer(issue["number"]) and status in active_states and
      not rerun_blocked_item?(item)
  end

  @spec rerun_blocked_item?(map()) :: boolean()
  defp rerun_blocked_item?(%{"content" => %{} = issue} = item) do
    body = issue["body"] || ""
    status = project_item_status(item)

    review_or_done_status?(status) or body_indicates_terminal_review_state?(body)
  end

  defp rerun_blocked_item?(_item), do: false

  @spec review_or_done_status?(String.t() | nil) :: boolean()
  defp review_or_done_status?(status) when is_binary(status) do
    status in ["In Review", "Done"]
  end

  defp review_or_done_status?(_status), do: false

  @spec body_indicates_terminal_review_state?(String.t()) :: boolean()
  defp body_indicates_terminal_review_state?(body) do
    String.match?(body, ~r/Final status:\s*(pr_created|in_review|done)/i) or
      String.match?(body, ~r/Pull request:\s*PR\s*#/i)
  end

  @spec project_item_status(map()) :: String.t() | nil
  defp project_item_status(item) do
    item
    |> get_in(["fieldValues", "nodes"])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"name" => name, "field" => %{"name" => "Status"}} when is_binary(name) -> name
      _other -> nil
    end)
  end

  @spec maybe_filter_issue_identifiers([Issue.t()], [String.t()]) :: [Issue.t()]
  defp maybe_filter_issue_identifiers(issues, []), do: issues

  defp maybe_filter_issue_identifiers(issues, identifiers) do
    wanted = MapSet.new(Enum.map(identifiers, &normalize_issue_number/1))
    Enum.filter(issues, &MapSet.member?(wanted, normalize_issue_number(&1.identifier)))
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

  @spec normalize_desired_state(atom() | String.t()) ::
          :todo | :in_progress | :done | :open | :closed
  defp normalize_desired_state(state) when is_atom(state),
    do: normalize_desired_state(Atom.to_string(state))

  @desired_state_map %{
    "released" => :open,
    "claimed" => :in_progress,
    "running" => :in_progress,
    "retry_queued" => :todo,
    "done" => :done,
    "closed" => :closed,
    "in_progress" => :in_progress,
    "todo" => :todo
  }

  defp normalize_desired_state(state) do
    normalized =
      state
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    Map.get(@desired_state_map, normalized, :open)
  end

  @spec sync_write_back(Issue.t(), map(), keyword()) ::
          :ok | {:ok, {:partial, atom(), term()}} | {:error, atom(), term()}
  defp sync_write_back(_issue, %{status: :gated}, _opts), do: :ok

  defp sync_write_back(%Issue{} = issue, attrs, opts) do
    with :ok <- sync_essential_write_back(issue, attrs, opts) do
      emit_write_back_stage(issue, :essential, :success, %{status: Map.get(attrs, :status)})

      case sync_optional_write_back(issue, attrs, opts) do
        :ok ->
          emit_write_back_stage(issue, :optional, :success, %{status: Map.get(attrs, :status)})
          :ok

        {:error, stage, reason} ->
          {:ok, {:partial, stage, reason}}
      end
    end
  end

  @spec sync_essential_write_back(Issue.t(), map(), keyword()) :: :ok | {:error, atom(), term()}
  defp sync_essential_write_back(%Issue{} = issue, attrs, opts) do
    with :ok <- maybe_update_issue_state(issue, attrs, opts) do
      maybe_sync_project_status(issue, attrs, opts)
    end
  end

  @spec sync_optional_write_back(Issue.t(), map(), keyword()) :: :ok | {:error, atom(), term()}
  defp sync_optional_write_back(%Issue{} = issue, attrs, opts) do
    with :ok <- maybe_sync_additional_project_fields(issue, attrs, opts),
         :ok <- sync_write_back_automation(issue, attrs, opts) do
      :ok
    end
  end

  @spec maybe_update_issue_state(Issue.t(), map(), keyword()) :: :ok | {:error, term()}
  defp maybe_update_issue_state(%Issue{} = issue, attrs, opts) do
    desired_state = lifecycle_issue_state(attrs, opts)

    if desired_issue_state_already_set?(issue, desired_state) do
      :ok
    else
      case update_issue_state(issue, desired_state, opts) do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, :issue_state_failed, reason}
      end
    end
  end

  @spec maybe_sync_project_status(Issue.t(), map(), keyword()) :: :ok | {:error, atom(), term()}
  defp maybe_sync_project_status(%Issue{} = issue, attrs, opts) do
    desired_status = lifecycle_project_state_name(attrs, opts)

    if is_nil(desired_status) do
      :ok
    else
      case fetch_project_item(issue, opts) do
        {:ok, item} ->
          current_status = project_item_status(item)

          if project_status_regression?(current_status, desired_status) do
            :ok
          else
            sync_project_field(item, "Status", desired_status, opts)
          end

        {:error, {:project_item_not_found, _identifier}} ->
          :ok

        {:error, reason} ->
          {:error, :project_item_lookup_failed, reason}
      end
    end
  end

  @spec project_status_regression?(String.t() | nil, String.t()) :: boolean()
  defp project_status_regression?(current_status, desired_status) do
    case {project_status_rank(current_status), project_status_rank(desired_status)} do
      {current_rank, desired_rank} when is_integer(current_rank) and is_integer(desired_rank) ->
        current_rank > desired_rank

      _ ->
        false
    end
  end

  @spec project_status_rank(String.t() | nil) :: integer() | nil
  defp project_status_rank("Todo"), do: 1
  defp project_status_rank("In Progress"), do: 2
  defp project_status_rank("In Review"), do: 3
  defp project_status_rank("Done"), do: 4
  defp project_status_rank(_status), do: nil

  @spec maybe_sync_additional_project_fields(Issue.t(), map(), keyword()) ::
          :ok | {:error, atom(), term()}
  defp maybe_sync_additional_project_fields(%Issue{} = issue, attrs, opts) do
    desired_fields = lifecycle_additional_project_fields(attrs, opts)

    if map_size(desired_fields) == 0 do
      :ok
    else
      case fetch_project_item(issue, opts) do
        {:ok, item} ->
          sync_all_project_fields(item, desired_fields, opts)

        {:error, {:project_item_not_found, _identifier}} ->
          :ok

        {:error, reason} ->
          {:error, :project_item_lookup_failed, reason}
      end
    end
  end

  @spec sync_all_project_fields(map(), map(), keyword()) :: :ok | {:error, atom(), term()}
  defp sync_all_project_fields(item, desired_fields, opts) do
    desired_fields
    |> Enum.reduce_while(:ok, fn {field_name, desired_value}, _acc ->
      case sync_project_field(item, field_name, desired_value, opts) do
        :ok -> {:cont, :ok}
        {:error, stage, reason} -> {:halt, {:error, stage, reason}}
      end
    end)
  end

  @spec sync_project_field(map(), String.t(), term(), keyword()) :: :ok | {:error, atom(), term()}
  defp sync_project_field(item, field_name, desired_value, opts) do
    with {:ok, field_definition} <- resolve_project_field(item, field_name),
         false <- project_field_value_matches?(item, field_definition, desired_value),
         {:ok, payload} <- project_field_update_payload(field_definition, desired_value),
         {:ok, _response} <-
           Client.update_project_field_value(
             item["projectId"],
             item["id"],
             field_definition["id"],
             payload,
             opts
           ) do
      :ok
    else
      true -> :ok
      {:error, {:project_field_not_found, _field_name}} -> :ok
      {:error, {:project_field_option_not_found, _field_name, _desired_value}} -> :ok
      {:error, {:project_field_iteration_not_found, _field_name, _desired_value}} -> :ok
      {:error, {:unsupported_project_field_type, _field_name}} -> :ok
      {:error, reason} -> {:error, project_field_failure_stage(field_name), reason}
    end
  end

  @spec sync_write_back_automation(Issue.t(), map(), keyword()) :: :ok | {:error, atom(), term()}
  defp sync_write_back_automation(%Issue{} = issue, attrs, opts) do
    with :ok <- maybe_cleanup_managed_labels(issue, attrs, opts),
         :ok <- maybe_add_lifecycle_labels(issue, attrs, opts) do
      maybe_assign_lifecycle_assignees(issue, attrs, opts)
    end
  end

  @spec maybe_cleanup_managed_labels(Issue.t(), map(), keyword()) ::
          :ok | {:error, atom(), term()}
  defp maybe_cleanup_managed_labels(%Issue{} = issue, attrs, opts) do
    existing_labels = MapSet.new(Enum.map(issue.labels, &normalize_value/1))
    desired_labels = MapSet.new(Enum.map(write_back_labels(attrs, opts), &normalize_value/1))

    labels_to_remove =
      issue.labels
      |> Enum.filter(fn label ->
        normalized = normalize_value(label)

        MapSet.member?(existing_labels, normalized) and
          managed_label?(label, opts) and
          not MapSet.member?(desired_labels, normalized)
      end)

    Enum.reduce_while(labels_to_remove, :ok, fn label, _acc ->
      case Client.remove_label(issue.identifier, label, opts) do
        {:ok, _response} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, :label_cleanup_failed, reason}}
      end
    end)
  end

  @spec maybe_add_lifecycle_labels(Issue.t(), map(), keyword()) :: :ok | {:error, atom(), term()}
  defp maybe_add_lifecycle_labels(%Issue{} = issue, attrs, opts) do
    issue_labels = issue.labels |> Enum.map(&normalize_value/1) |> MapSet.new()

    labels =
      attrs
      |> write_back_labels(opts)
      |> Enum.reject(fn label -> MapSet.member?(issue_labels, normalize_value(label)) end)

    case labels do
      [] ->
        :ok

      labels ->
        case Client.add_labels(issue.identifier, labels, opts) do
          {:ok, _response} -> :ok
          {:error, reason} -> {:error, :label_sync_failed, reason}
        end
    end
  end

  @spec maybe_assign_lifecycle_assignees(Issue.t(), map(), keyword()) ::
          :ok | {:error, atom(), term()}
  defp maybe_assign_lifecycle_assignees(%Issue{} = issue, attrs, opts) do
    current_assignees = issue.assignees |> Enum.map(&normalize_value/1) |> MapSet.new()

    desired_assignees =
      attrs
      |> write_back_assignees(opts)
      |> merge_assignees(issue, opts)
      |> Enum.uniq()

    if Enum.all?(desired_assignees, fn assignee ->
         MapSet.member?(current_assignees, normalize_value(assignee))
       end) do
      :ok
    else
      case Client.assign_issue(issue.identifier, desired_assignees, opts) do
        {:ok, _response} -> :ok
        {:error, reason} -> {:error, :assignee_sync_failed, reason}
      end
    end
  end

  @spec annotate_partial_write_back(Issue.t(), map(), atom(), term(), keyword()) :: :ok
  defp annotate_partial_write_back(%Issue{} = issue, attrs, stage, reason, opts) do
    partial_attrs =
      attrs
      |> Map.new()
      |> Map.put(:partial_write_back, true)
      |> Map.put(:partial_write_back_stage, stage)
      |> Map.put(:partial_write_back_reason, inspect(reason))

    partial_body = render_run_record(issue, partial_attrs)
    partial_comment = managed_block(partial_body)

    case create_comment(issue.identifier, partial_comment, opts) do
      {:ok, _response} ->
        emit_write_back_stage(issue, :annotation, :success, %{
          failed_stage: stage,
          reason: inspect(reason)
        })

      {:error, annotation_reason} ->
        emit_write_back_stage(issue, :annotation, :failed, %{
          failed_stage: stage,
          reason: inspect(annotation_reason)
        })
    end

    :ok
  end

  @spec emit_write_back_stage(Issue.t(), atom(), atom(), map()) :: :ok
  defp emit_write_back_stage(%Issue{} = issue, stage, outcome, metadata) do
    Observability.record_write_back_stage(issue.identifier, :github, stage, outcome, metadata)
    Telemetry.emit_write_back_stage(issue.identifier, :github, stage, outcome, metadata)
  end

  @spec project_field_failure_stage(String.t()) :: atom()
  defp project_field_failure_stage("Status"), do: :project_status_failed
  defp project_field_failure_stage(_field_name), do: :project_field_sync_failed

  @spec write_back_labels(map(), keyword()) :: [String.t()]
  defp write_back_labels(attrs, opts) do
    lifecycle_write_back_values(opts, attrs, :labels)
  end

  @spec write_back_assignees(map(), keyword()) :: [String.t()]
  defp write_back_assignees(attrs, opts) do
    lifecycle_write_back_values(opts, attrs, :assignees)
  end

  @spec merge_assignees([String.t()], Issue.t(), keyword()) :: [String.t()]
  defp merge_assignees(assignees, %Issue{} = issue, opts) do
    mode =
      opts
      |> Keyword.get(:write_back, [])
      |> Keyword.get(:assignee_mode, :merge)

    case mode do
      :replace -> assignees
      "replace" -> assignees
      _other -> issue.assignees ++ assignees
    end
  end

  @spec lifecycle_write_back_values(keyword(), map(), atom()) :: [String.t()]
  defp lifecycle_write_back_values(opts, attrs, key) do
    write_back = Keyword.get(opts, :write_back, [])
    status = Map.get(attrs, :status)
    result = Map.get(attrs, :result)

    if Keyword.get(write_back, :enabled, true) do
      write_back
      |> state_write_back_values(status, result, key)
      |> Enum.map(&to_string/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
    else
      []
    end
  end

  @spec state_write_back_values(keyword(), atom() | nil, atom() | nil, atom()) :: [term()]
  defp state_write_back_values(write_back, :released, result, key) do
    released = Keyword.get(write_back, :released, [])
    result_key = normalize_result_key(result)
    result_opts = Keyword.get(released, result_key, [])

    List.wrap(Keyword.get(write_back, key)) ++
      List.wrap(Keyword.get(Keyword.get(released, :any, []), key)) ++
      List.wrap(Keyword.get(result_opts, key))
  end

  defp state_write_back_values(write_back, status, _result, key) when is_atom(status) do
    List.wrap(Keyword.get(write_back, key)) ++
      List.wrap(Keyword.get(Keyword.get(write_back, status, []), key))
  end

  defp state_write_back_values(write_back, _status, _result, key),
    do: List.wrap(Keyword.get(write_back, key))

  @spec normalize_result_key(atom() | nil) :: atom()
  defp normalize_result_key(nil), do: :any

  defp normalize_result_key(result) when result in [:success, :failed, :cancelled, :any],
    do: result

  defp normalize_result_key(result) when is_atom(result), do: result
  defp normalize_result_key(_result), do: :any

  @spec managed_label?(String.t(), keyword()) :: boolean()
  defp managed_label?(label, opts) do
    write_back = Keyword.get(opts, :write_back, [])
    normalized = normalize_value(label)

    managed_labels =
      write_back
      |> Keyword.get(:managed_labels, [])
      |> Enum.map(&normalize_value/1)
      |> MapSet.new()

    managed_prefixes =
      write_back
      |> Keyword.get(:managed_label_prefixes, [])
      |> Enum.map(&normalize_value/1)

    MapSet.member?(managed_labels, normalized) or
      Enum.any?(managed_prefixes, &String.starts_with?(normalized, &1))
  end

  @spec fetch_project_item(Issue.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp fetch_project_item(%Issue{} = issue, opts) do
    with true <-
           Keyword.has_key?(opts, :project_number) or
             {:error, {:project_item_not_found, issue.identifier}},
         {:ok, items} <- Client.list_project_items(opts),
         %{} = item <- Enum.find(items, &project_item_matches_issue?(&1, issue.identifier)) do
      {:ok, item}
    else
      nil -> {:error, {:project_item_not_found, issue.identifier}}
      false -> {:error, {:project_item_not_found, issue.identifier}}
      {:error, _reason} = error -> error
    end
  end

  @spec find_project_status_value(map()) :: map() | nil
  defp find_project_status_value(item) do
    item
    |> get_in(["fieldValues", "nodes"])
    |> List.wrap()
    |> Enum.find(fn
      %{"field" => %{"name" => "Status"}} -> true
      _other -> false
    end)
  end

  @spec resolve_project_field(map(), String.t()) :: {:ok, map()} | {:error, term()}
  defp resolve_project_field(item, field_name) do
    desired_name = normalize_value(field_name)

    case Enum.find(project_fields(item), fn field ->
           normalize_value(field["name"]) == desired_name
         end) do
      %{} = field -> {:ok, field}
      nil -> {:error, {:project_field_not_found, field_name}}
    end
  end

  @spec project_fields(map()) :: [map()]
  defp project_fields(item) do
    status_field =
      item
      |> find_project_status_value()
      |> case do
        %{"field" => %{} = field} -> [field]
        _other -> []
      end

    explicit_fields =
      item
      |> Map.get("projectFields", [])
      |> List.wrap()
      |> Enum.filter(&is_map/1)

    (status_field ++ explicit_fields)
    |> Enum.uniq_by(&project_field_identity/1)
  end

  @spec project_field_identity(map()) :: String.t()
  defp project_field_identity(field),
    do: to_string(field["id"] || field["name"] || inspect(field))

  @spec project_field_value_matches?(map(), map(), term()) :: boolean()
  defp project_field_value_matches?(item, field_definition, desired_value) do
    current_value = current_project_field_value(item, field_definition["name"])
    kind = project_field_kind(field_definition)
    field_values_equal?(kind, current_value, desired_value)
  end

  @spec field_values_equal?(atom(), term(), term()) :: boolean()
  defp field_values_equal?(kind, current, desired) when kind in [:single_select, :iteration],
    do: normalize_value(current) == normalize_value(desired)

  defp field_values_equal?(kind, current, desired) when kind in [:text, :date],
    do: to_string(current || "") == to_string(desired || "")

  defp field_values_equal?(:number, current, desired),
    do: normalize_number(current) == normalize_number(desired)

  defp field_values_equal?(_kind, _current, _desired), do: false

  @spec current_project_field_value(map(), String.t()) :: term()
  defp current_project_field_value(item, field_name) do
    desired_name = normalize_value(field_name)

    item
    |> get_in(["fieldValues", "nodes"])
    |> List.wrap()
    |> Enum.find_value(fn
      %{"field" => %{"name" => name}, "name" => value} when is_binary(name) ->
        if normalize_value(name) == desired_name, do: value

      %{"field" => %{"name" => name}, "text" => value} when is_binary(name) ->
        if normalize_value(name) == desired_name, do: value

      %{"field" => %{"name" => name}, "date" => value} when is_binary(name) ->
        if normalize_value(name) == desired_name, do: value

      %{"field" => %{"name" => name}, "number" => value} when is_binary(name) ->
        if normalize_value(name) == desired_name, do: value

      %{"field" => %{"name" => name}, "title" => value} when is_binary(name) ->
        if normalize_value(name) == desired_name, do: value

      _other ->
        nil
    end)
  end

  @spec project_field_update_payload(map(), term()) :: {:ok, map()} | {:error, term()}
  defp project_field_update_payload(field_definition, desired_value) do
    kind = project_field_kind(field_definition)
    build_field_payload(kind, field_definition, desired_value)
  end

  @spec build_field_payload(atom(), map(), term()) :: {:ok, map()} | {:error, term()}
  defp build_field_payload(:single_select, field_definition, desired_value) do
    case Enum.find(List.wrap(field_definition["options"]), &(&1["name"] == desired_value)) do
      %{"id" => option_id} ->
        {:ok, %{single_select_option_id: option_id}}

      nil ->
        {:error, {:project_field_option_not_found, field_definition["name"], desired_value}}
    end
  end

  defp build_field_payload(:text, _field_definition, desired_value),
    do: {:ok, %{text: to_string(desired_value)}}

  defp build_field_payload(:date, _field_definition, desired_value),
    do: {:ok, %{date: to_string(desired_value)}}

  defp build_field_payload(:number, field_definition, desired_value) do
    case normalize_number(desired_value) do
      nil -> {:error, {:invalid_project_field_number, field_definition["name"], desired_value}}
      number -> {:ok, %{number: number}}
    end
  end

  defp build_field_payload(:iteration, field_definition, desired_value) do
    iterations = get_in(field_definition, ["configuration", "iterations"]) |> List.wrap()

    case Enum.find(iterations, &(&1["title"] == desired_value || &1["id"] == desired_value)) do
      %{"id" => iteration_id} ->
        {:ok, %{iteration_id: iteration_id}}

      nil ->
        {:error, {:project_field_iteration_not_found, field_definition["name"], desired_value}}
    end
  end

  defp build_field_payload(_kind, field_definition, _desired_value),
    do: {:error, {:unsupported_project_field_type, field_definition["name"]}}

  @spec project_field_kind(map()) :: atom()
  defp project_field_kind(field_definition) do
    cond do
      is_list(field_definition["options"]) -> :single_select
      is_map(field_definition["configuration"]) -> :iteration
      normalize_value(field_definition["dataType"]) == "text" -> :text
      normalize_value(field_definition["dataType"]) == "date" -> :date
      normalize_value(field_definition["dataType"]) == "number" -> :number
      normalize_value(field_definition["name"]) == "status" -> :single_select
      true -> :text
    end
  end

  @spec normalize_number(term()) :: float() | nil
  defp normalize_number(value) when is_integer(value), do: value * 1.0
  defp normalize_number(value) when is_float(value), do: value

  defp normalize_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _other -> nil
    end
  end

  defp normalize_number(_value), do: nil

  @spec project_item_matches_issue?(map(), String.t()) :: boolean()
  defp project_item_matches_issue?(item, identifier) do
    case get_in(item, ["content", "number"]) do
      number when is_integer(number) -> number == normalize_issue_number(identifier)
      _other -> false
    end
  end

  @spec lifecycle_from_opts(keyword()) :: Lifecycle.t()
  defp lifecycle_from_opts(opts) do
    case Keyword.get(opts, :lifecycle) do
      %Lifecycle{} = lc -> lc
      lifecycle_opts when is_list(lifecycle_opts) -> Lifecycle.new(lifecycle_opts)
      nil -> lifecycle_from_legacy_opts(opts)
    end
  end

  @spec lifecycle_from_legacy_opts(keyword()) :: Lifecycle.t()
  defp lifecycle_from_legacy_opts(opts) do
    write_back = Keyword.get(opts, :write_back, [])

    in_progress_name =
      List.first(Keyword.get(write_back, :in_progress_state_names, ["In Progress"]))

    todo_name = todo_project_state_name(opts, in_progress_name)

    review_name =
      List.first(Keyword.get(write_back, :review_state_names, ["In Review"]))

    Lifecycle.new(
      project_status_mapping: %{
        {:claimed, :any} => in_progress_name,
        {:running, :any} => in_progress_name,
        {:retry_queued, :any} => todo_name,
        {:released, :success} => review_name,
        {:released, :any} => todo_name
      }
    )
  end

  @spec lifecycle_issue_state(map(), keyword()) :: atom()
  defp lifecycle_issue_state(attrs, opts) do
    lc = lifecycle_from_opts(opts)
    status = Map.get(attrs, :status)
    result = Map.get(attrs, :result)
    Lifecycle.resolve_issue_state(lc, status, result)
  end

  @spec lifecycle_project_state_name(map(), keyword()) :: String.t() | nil
  defp lifecycle_project_state_name(attrs, opts) do
    lc = lifecycle_from_opts(opts)
    status = Map.get(attrs, :status)
    result = Map.get(attrs, :result)
    Lifecycle.resolve_project_status(lc, status, result)
  end

  @spec lifecycle_project_fields(map(), keyword()) :: map()
  defp lifecycle_project_fields(attrs, opts) do
    lc = lifecycle_from_opts(opts)
    status = Map.get(attrs, :status)
    result = Map.get(attrs, :result)

    lc
    |> Lifecycle.resolve_project_fields(status, result)
    |> Map.put_new_lazy("Status", fn -> lifecycle_project_state_name(attrs, opts) end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec lifecycle_additional_project_fields(map(), keyword()) :: map()
  defp lifecycle_additional_project_fields(attrs, opts) do
    attrs
    |> lifecycle_project_fields(opts)
    |> Map.delete("Status")
  end

  @spec todo_project_state_name(keyword(), String.t() | nil) :: String.t() | nil
  defp todo_project_state_name(opts, in_progress_name) do
    opts
    |> Keyword.get(:active_states, ["In Progress", "Todo"])
    |> Enum.find(fn state_name -> state_name != in_progress_name end) || in_progress_name
  end

  @spec normalize_issue_state(map()) :: String.t()
  defp normalize_issue_state(issue) do
    case issue["state"] do
      value when is_binary(value) -> String.capitalize(value)
      _ -> if(issue["closed_at"], do: "Closed", else: "Open")
    end
  end

  @spec desired_issue_state_already_set?(Issue.t(), atom()) :: boolean()
  defp desired_issue_state_already_set?(%Issue{} = issue, desired_state) do
    normalized = normalize_value(issue.state)

    case desired_state do
      state when state in [:todo, :in_progress, :open] ->
        normalized in ["open", "todo", "in progress"]

      state when state in [:done, :closed] ->
        normalized in ["closed", "done"]
    end
  end

  @spec extract_labels(term()) :: [String.t()]
  defp extract_labels(labels) when is_list(labels), do: Enum.map(labels, &label_name/1)
  defp extract_labels(_labels), do: []

  @spec extract_assignees(term()) :: [String.t()]
  defp extract_assignees(assignees) when is_list(assignees),
    do: Enum.map(assignees, &assignee_login/1)

  defp extract_assignees(_assignees), do: []

  @spec extract_blocked_by_identifiers([map()]) :: [String.t()]
  defp extract_blocked_by_identifiers(issues) do
    issues
    |> Enum.filter(&dependency_open?/1)
    |> Enum.map(&dependency_identifier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @spec dependency_open?(map()) :: boolean()
  defp dependency_open?(issue) do
    normalized =
      issue
      |> Map.get("state", "")
      |> normalize_value()

    normalized not in ["closed", "done"]
  end

  @spec dependency_identifier(map()) :: String.t() | nil
  defp dependency_identifier(%{"number" => number}) when is_integer(number),
    do: Integer.to_string(number)

  defp dependency_identifier(%{"number" => number}) when is_binary(number), do: number
  defp dependency_identifier(_issue), do: nil

  @spec label_name(term()) :: String.t()
  defp label_name(%{"name" => name}), do: name
  defp label_name(name) when is_binary(name), do: name
  defp label_name(other), do: to_string(other)

  @spec assignee_login(term()) :: String.t()
  defp assignee_login(%{"login" => login}), do: login
  defp assignee_login(login) when is_binary(login), do: login
  defp assignee_login(other), do: to_string(other)

  @spec normalize_value(term()) :: String.t()
  defp normalize_value(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  @spec format_metadata_value(term()) :: String.t()
  defp format_metadata_value(value) when is_binary(value), do: value
  defp format_metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp format_metadata_value(value), do: inspect(value)
end
