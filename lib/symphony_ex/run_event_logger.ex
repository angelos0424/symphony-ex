defmodule SymphonyEx.RunEventLogger do
  @moduledoc """
  Appends newline-delimited JSON run events under each workspace.

  This provides a TS-compatible local breadcrumb trail in
  `.symphony-run-events.ndjson` without requiring a separate process.
  """

  alias SymphonyEx.Domain.{Events, Issue}

  @events_file ".symphony-run-events.ndjson"

  @type event_type ::
          :run_started
          | :turn_started
          | :turn_completed
          | :approval_denied
          | :run_finished
          | :turn_failed
          | :turn_cancelled
          | :agent_message
          | :item_started
          | :item_completed
          | :diff_updated
          | :notification

  @spec append(workspace_path :: Path.t(), event_type(), map()) :: :ok | {:error, term()}
  def append(workspace_path, event_type, attrs \\ %{}) when is_binary(workspace_path) do
    payload =
      attrs
      |> stringify_keys()
      |> Map.merge(%{
        "event" => Atom.to_string(event_type),
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      })

    with {:ok, encoded} <- Jason.encode(payload),
         :ok <- File.mkdir_p(workspace_path) do
      File.write(events_path(workspace_path), encoded <> "\n", [:append])
    end
  end

  @spec log_run_started(Path.t(), Issue.t(), map()) :: :ok | {:error, term()}
  def log_run_started(workspace_path, %Issue{} = issue, attrs \\ %{}) do
    append(
      workspace_path,
      :run_started,
      Map.merge(issue_attrs(issue), attrs)
    )
  end

  @spec log_run_finished(Path.t(), Issue.t(), map()) :: :ok | {:error, term()}
  def log_run_finished(workspace_path, %Issue{} = issue, attrs \\ %{}) do
    append(
      workspace_path,
      :run_finished,
      Map.merge(issue_attrs(issue), attrs)
    )
  end

  @spec log_app_event(Path.t(), Issue.t(), String.t() | nil, Events.t()) :: :ok | {:error, term()}
  def log_app_event(workspace_path, %Issue{} = issue, thread_id, %Events{} = event) do
    append(
      workspace_path,
      map_event_type(event),
      issue_attrs(issue)
      |> put_if_present("thread_id", thread_id)
      |> put_if_present("raw_method", event.raw_method)
      |> put_if_present("message", event.message)
      |> put_if_present("usage", event.usage)
      |> Map.put("event_timestamp", event.timestamp)
      |> Map.put("params", event.params)
    )
  end

  @spec events_path(Path.t()) :: Path.t()
  def events_path(workspace_path), do: Path.join(workspace_path, @events_file)

  @spec issue_attrs(Issue.t()) :: map()
  defp issue_attrs(%Issue{} = issue) do
    %{
      "issue_id" => issue.id,
      "issue_identifier" => issue.identifier,
      "issue_title" => issue.title
    }
  end

  @spec map_event_type(Events.t()) :: event_type()
  defp map_event_type(%Events{event: :approval_requested}), do: :approval_denied
  defp map_event_type(%Events{event: event}), do: event

  @spec put_if_present(map(), String.t(), term()) :: map()
  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, _key, ""), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end
end
