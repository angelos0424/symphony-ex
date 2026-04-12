defmodule SymphonyEx.SessionStore do
  @moduledoc """
  Persists durable per-workspace session breadcrumbs for recovery.

  Session metadata lives at `.symphony-session.json` inside the workspace so a
  later process can decide whether a Codex thread is reusable after crashes or
  restarts.
  """

  @session_file ".symphony-session.json"
  @allowed_phases ~w(initializing running completed failed)

  @type phase :: :initializing | :running | :completed | :failed

  @type session_data :: %{
          thread_id: String.t() | nil,
          turn_id: String.t() | nil,
          session_id: String.t(),
          issue_id: String.t() | nil,
          issue_identifier: String.t() | nil,
          turns_executed: non_neg_integer(),
          capability_profile: map(),
          recovery_count: non_neg_integer(),
          last_event: String.t() | nil,
          phase: phase(),
          error: String.t() | nil,
          error_category: String.t() | nil,
          updated_at: String.t()
        }

  @spec session_path(Path.t()) :: Path.t()
  def session_path(workspace_path), do: Path.join(workspace_path, @session_file)

  @spec load(Path.t()) :: {:ok, session_data() | nil} | {:error, term()}
  def load(workspace_path) do
    path = session_path(workspace_path)

    case File.read(path) do
      {:ok, contents} ->
        with {:ok, decoded} <- Jason.decode(contents) do
          normalize_session(decoded)
        end

      {:error, :enoent} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec save(Path.t(), map()) :: {:ok, session_data()} | {:error, term()}
  def save(workspace_path, attrs) when is_map(attrs) do
    with {:ok, existing} <- load(workspace_path),
         {:ok, session} <- merge_and_normalize(existing || %{}, attrs),
         :ok <- File.mkdir_p(workspace_path),
         {:ok, encoded} <- Jason.encode(session),
         :ok <- File.write(session_path(workspace_path), encoded <> "\n") do
      {:ok, session}
    end
  end

  @spec delete(Path.t()) :: :ok | {:error, term()}
  def delete(workspace_path) do
    case File.rm(session_path(workspace_path)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec recoverable?(session_data() | nil) :: boolean()
  def recoverable?(nil), do: false

  def recoverable?(session) do
    session.phase not in [:completed] and
      session.recovery_count <= 3 and
      is_binary(session.thread_id) and
      session.thread_id != "" and
      get_in(session, [:capability_profile, "supports_thread_reuse"]) == true
  end

  @spec mark_recovered(Path.t()) :: {:ok, session_data() | nil} | {:error, term()}
  def mark_recovered(workspace_path) do
    case load(workspace_path) do
      {:ok, session} when not is_nil(session) ->
        save(workspace_path, %{
          recovery_count: session.recovery_count + 1,
          phase: :running,
          last_event: "session_recovered"
        })

      {:ok, nil} ->
        {:ok, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec merge_and_normalize(map(), map()) :: {:ok, session_data()} | {:error, term()}
  defp merge_and_normalize(existing, attrs) do
    merged =
      existing
      |> stringify_keys()
      |> Map.merge(stringify_keys(attrs))
      |> Map.put_new("session_id", generate_session_id())
      |> Map.put_new("turns_executed", 0)
      |> Map.put_new("capability_profile", %{})
      |> Map.put_new("recovery_count", 0)
      |> Map.put_new("phase", "initializing")
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())

    normalize_session(merged)
  end

  @spec normalize_session(map()) :: {:ok, session_data()} | {:error, term()}
  defp normalize_session(data) when is_map(data) do
    with {:ok, phase} <- validate_phase(data),
         :ok <- validate_integer_field(data, "turns_executed"),
         :ok <- validate_integer_field(data, "recovery_count") do
      {:ok, build_session_data(data, phase)}
    end
  end

  @spec validate_phase(map()) :: {:ok, phase()} | {:error, term()}
  defp validate_phase(data) do
    case normalize_phase(data["phase"]) do
      nil -> {:error, {:invalid_session_phase, data["phase"]}}
      phase -> {:ok, phase}
    end
  end

  @spec validate_integer_field(map(), String.t()) :: :ok | {:error, term()}
  defp validate_integer_field(data, field) do
    if is_integer(data[field] || 0) do
      :ok
    else
      {:error, {invalid_integer_field_error(field), data[field]}}
    end
  end

  @spec invalid_integer_field_error(String.t()) :: atom()
  defp invalid_integer_field_error("turns_executed"), do: :invalid_turns_executed
  defp invalid_integer_field_error("recovery_count"), do: :invalid_recovery_count
  defp invalid_integer_field_error(_field), do: :invalid_integer_field

  @spec build_session_data(map(), phase()) :: session_data()
  defp build_session_data(data, phase) do
    %{
      thread_id: blank_to_nil(data["thread_id"]),
      turn_id: blank_to_nil(data["turn_id"]),
      session_id: to_string(data["session_id"] || generate_session_id()),
      issue_id: blank_to_nil(data["issue_id"]),
      issue_identifier: blank_to_nil(data["issue_identifier"]),
      turns_executed: data["turns_executed"] || 0,
      capability_profile: normalize_capabilities(data["capability_profile"] || %{}),
      recovery_count: data["recovery_count"] || 0,
      last_event: blank_to_nil(data["last_event"]),
      phase: phase,
      error: blank_to_nil(data["error"]),
      error_category: blank_to_nil(data["error_category"]),
      updated_at: to_string(data["updated_at"] || DateTime.utc_now() |> DateTime.to_iso8601())
    }
  end

  defp normalize_phase(phase) when is_atom(phase), do: normalize_phase(Atom.to_string(phase))

  defp normalize_phase(phase) when phase in @allowed_phases do
    String.to_existing_atom(phase)
  end

  defp normalize_phase(_phase), do: nil

  @spec normalize_capabilities(map()) :: map()
  defp normalize_capabilities(capabilities) when is_map(capabilities) do
    capabilities
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) do
    Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)
  end

  @spec blank_to_nil(term()) :: String.t() | nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: to_string(value)

  @spec generate_session_id() :: String.t()
  defp generate_session_id do
    "session-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))
  end
end
