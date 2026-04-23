defmodule SymphonyEx.Workspace do
  @moduledoc """
  Manages issue-scoped git worktrees under the configured workspace root.
  """

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.{SessionStore, SourceRepo}

  @default_stale_orphan_ttl_ms :timer.hours(1)

  @type shell_fun :: (String.t(), [String.t()], keyword() -> {binary(), non_neg_integer()})
  @type prepare_reason :: :fresh | {:reset, atom()} | {:recover, SessionStore.session_data()}
  @type prepare_result :: %{path: String.t(), reason: prepare_reason()}

  @spec path_for_issue(String.t(), Issue.t()) :: String.t()
  def path_for_issue(root, %Issue{identifier: identifier}) do
    Path.join(root, sanitize_segment(identifier))
  end

  @spec prepare(Issue.t(), keyword()) :: {:ok, prepare_result()} | {:error, term()}
  def prepare(issue, opts) do
    root = Keyword.fetch!(opts, :root)
    source_repo_path = Keyword.fetch!(opts, :source_repo_path)
    shell = Keyword.get(opts, :shell_fun, &System.cmd/3)
    hooks = Keyword.get(opts, :hooks, [])
    path = path_for_issue(root, issue)

    with :ok <- ensure_within_root(root, path),
         :ok <- File.mkdir_p(root),
         :ok <- SourceRepo.ensure_ready(opts),
         {:ok, reason} <- preflight_session(path) do
      case reason do
        {:recover, session} ->
          {:ok, %{path: path, reason: {:recover, session}}}

        :fresh ->
          create_fresh_worktree(path, root, source_repo_path, shell, hooks, issue, :fresh)

        {:reset, reset_reason} ->
          create_fresh_worktree(path, root, source_repo_path, shell, hooks, issue, {
            :reset,
            reset_reason
          })
      end
    else
      {:error, _} = error -> error
    end
  end

  @spec create(Issue.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create(issue, opts) do
    with {:ok, %{path: path}} <- prepare(issue, opts) do
      {:ok, path}
    end
  end

  @spec cleanup_inactive_worktrees(keyword()) :: :ok
  def cleanup_inactive_worktrees(opts) do
    root = Keyword.fetch!(opts, :root)
    source_repo_path = Keyword.fetch!(opts, :source_repo_path)
    shell = Keyword.get(opts, :shell_fun, &System.cmd/3)
    tracker = Keyword.get(opts, :tracker)
    tracker_opts = Keyword.get(opts, :tracker_opts, [])
    active_issue_identifiers = MapSet.new(Keyword.get(opts, :active_issue_identifiers, []))
    tracked_worktrees = MapSet.new(active_worktree_paths(source_repo_path, shell))

    if is_atom(tracker) do
      root
      |> inactive_worktree_candidates(source_repo_path, tracked_worktrees)
      |> Enum.reject(&worktree_active_for_issue?(&1, active_issue_identifiers))
      |> Enum.each(fn {path, issue_identifier} ->
        if remove_inactive_worktree?(issue_identifier, tracker, tracker_opts) do
          _ = remove(path, opts)
        end
      end)

      root
      |> orphaned_worktree_candidates(source_repo_path, tracked_worktrees)
      |> Enum.reject(&worktree_active_for_issue?(&1, active_issue_identifiers))
      |> Enum.each(fn {path, issue_identifier} ->
        if remove_orphaned_worktree?(path, issue_identifier, tracker, tracker_opts, opts) do
          _ = remove_orphaned_path(path)
        end
      end)
    end

    _ = shell.("git", ["worktree", "prune"], cd: source_repo_path)
    :ok
  end

  @spec remove(String.t(), keyword()) :: :ok | {:error, term()}
  def remove(path, opts) do
    source_repo_path = Keyword.fetch!(opts, :source_repo_path)
    root = Keyword.fetch!(opts, :root)
    shell = Keyword.get(opts, :shell_fun, &System.cmd/3)
    hooks = Keyword.get(opts, :hooks, [])

    with :ok <- ensure_within_root(root, path),
         :ok <- run_hook(:before_remove, hooks, path, shell, nil),
         {_, 0} <- shell.("git", ["worktree", "remove", "--force", path], cd: source_repo_path) do
      :ok
    else
      {:error, _} = error -> error
      {output, code} when is_integer(code) -> {:error, {:git_failed, code, output}}
    end
  end

  @spec run_lifecycle_hook(:before_run | :after_run, String.t(), keyword(), Issue.t()) ::
          :ok | {:error, term()}
  def run_lifecycle_hook(name, path, opts, issue) do
    hooks = Keyword.get(opts, :hooks, [])
    shell = Keyword.get(opts, :shell_fun, &System.cmd/3)
    run_hook(name, hooks, path, shell, issue)
  end

  @spec ensure_within_root(String.t(), String.t()) :: :ok | {:error, term()}
  def ensure_within_root(root, path) do
    expanded_root = Path.expand(root)
    expanded_path = Path.expand(path)

    if expanded_path == expanded_root or String.starts_with?(expanded_path, expanded_root <> "/") do
      :ok
    else
      {:error, {:outside_workspace_root, expanded_path}}
    end
  end

  @spec sanitize_segment(String.t()) :: String.t()
  def sanitize_segment(segment) do
    segment
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/u, "-")
    |> String.trim("-")
  end

  @spec create_fresh_worktree(
          String.t(),
          String.t(),
          String.t(),
          shell_fun(),
          keyword(),
          Issue.t(),
          prepare_reason()
        ) :: {:ok, prepare_result()} | {:error, term()}
  defp create_fresh_worktree(path, root, source_repo_path, shell, hooks, issue, reason) do
    with :ok <- cleanup_stale_worktree_path(root, path, source_repo_path, shell),
         {_, 0} <- shell.("git", worktree_add_args(path, issue), cd: source_repo_path),
         :ok <- ensure_gstack_skills_available(path),
         :ok <- run_hook(:after_create, hooks, path, shell, issue) do
      {:ok, %{path: path, reason: reason}}
    else
      {:error, _} = error -> error
      {output, code} when is_integer(code) -> {:error, {:git_failed, code, output}}
    end
  end

  @spec worktree_add_args(String.t(), Issue.t()) :: [String.t()]
  defp worktree_add_args(path, %Issue{target_branch: target_branch})
       when is_binary(target_branch) do
    branch = String.trim(target_branch)

    if branch == "" do
      ["worktree", "add", "--detach", path, "HEAD"]
    else
      [
        "worktree",
        "add",
        "--track",
        "-B",
        branch,
        path,
        "refs/remotes/origin/#{branch}"
      ]
    end
  end

  defp worktree_add_args(path, %Issue{}), do: ["worktree", "add", "--detach", path, "HEAD"]

  @spec ensure_gstack_skills_available(String.t()) :: :ok | {:error, term()}
  defp ensure_gstack_skills_available(worktree_path) do
    if File.dir?(worktree_path) do
      case detect_gstack_skill_root() do
        nil ->
          :ok

        source_root ->
          target_root = Path.join([worktree_path, ".agents", "skills"])

          with :ok <- File.mkdir_p(target_root) do
            source_root
            |> File.ls!()
            |> Enum.reduce_while(:ok, fn entry, :ok ->
              source_path = Path.join(source_root, entry)
              target_path = Path.join(target_root, entry)

              cond do
                not File.dir?(source_path) ->
                  {:cont, :ok}

                File.exists?(target_path) ->
                  {:cont, :ok}

                true ->
                  case File.ln_s(source_path, target_path) do
                    :ok ->
                      {:cont, :ok}

                    {:error, _reason} ->
                      case File.cp_r(source_path, target_path) do
                        {:ok, _paths} ->
                          {:cont, :ok}

                        {:error, reason, _path} ->
                          {:halt, {:error, {:gstack_sync_failed, reason}}}
                      end
                  end
              end
            end)
          end
      end
    else
      :ok
    end
  end

  @spec detect_gstack_skill_root() :: String.t() | nil
  defp detect_gstack_skill_root do
    home = System.user_home()

    [
      System.get_env("GSTACK_ROOT"),
      Path.join([home, ".gstack", "repos", "gstack", ".agents", "skills"]),
      Path.join([home, ".codex", "skills", "gstack"])
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.find(&File.dir?/1)
  end

  @spec preflight_session(String.t()) :: {:ok, prepare_reason()} | {:error, term()}
  defp preflight_session(path) do
    case SessionStore.load(path) do
      {:ok, nil} -> {:ok, :fresh}
      {:ok, session} -> evaluate_existing_session(path, session)
      {:error, :enoent} -> {:ok, :fresh}
      {:error, reason} -> {:error, {:session_preflight_failed, reason}}
    end
  end

  @spec evaluate_existing_session(String.t(), SessionStore.session_data()) ::
          {:ok, prepare_reason()} | {:error, term()}
  defp evaluate_existing_session(_path, session) when is_map_key(session, :phase) do
    cond do
      SessionStore.recoverable?(session) -> {:ok, {:recover, session}}
      session.phase == :completed -> {:ok, {:reset, :completed_session}}
      session.recovery_count > 3 -> {:ok, {:reset, :recovery_limit_exhausted}}
      true -> {:ok, {:reset, :nonrecoverable_session}}
    end
  end

  @spec inactive_worktree_candidates(String.t(), String.t(), MapSet.t(String.t())) ::
          [{String.t(), String.t()}]
  defp inactive_worktree_candidates(root, source_repo_path, tracked_worktrees) do
    expanded_source_repo_path = Path.expand(source_repo_path)

    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.map(&Path.join(root, &1))
      |> Enum.filter(fn path ->
        expanded = Path.expand(path)

        File.dir?(path) and expanded != expanded_source_repo_path and
          MapSet.member?(tracked_worktrees, expanded)
      end)
      |> Enum.flat_map(fn path ->
        case issue_identifier_for_path(path) do
          nil -> []
          identifier -> [{path, identifier}]
        end
      end)
    else
      []
    end
  end

  @spec orphaned_worktree_candidates(String.t(), String.t(), MapSet.t(String.t())) ::
          [{String.t(), String.t()}]
  defp orphaned_worktree_candidates(root, source_repo_path, tracked_worktrees) do
    expanded_source_repo_path = Path.expand(source_repo_path)

    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.map(&Path.join(root, &1))
      |> Enum.filter(fn path ->
        expanded = Path.expand(path)

        File.dir?(path) and expanded != expanded_source_repo_path and
          not MapSet.member?(tracked_worktrees, expanded)
      end)
      |> Enum.flat_map(fn path ->
        case issue_identifier_for_path(path) do
          nil -> []
          identifier -> [{path, identifier}]
        end
      end)
    else
      []
    end
  end

  @spec issue_identifier_for_path(String.t()) :: String.t() | nil
  defp issue_identifier_for_path(path) do
    case SessionStore.load(path) do
      {:ok, %{issue_identifier: identifier}} when is_binary(identifier) and identifier != "" ->
        identifier

      _ ->
        case Path.basename(path) do
          "" -> nil
          value -> value
        end
    end
  end

  @spec worktree_active_for_issue?({String.t(), String.t()}, MapSet.t(String.t())) :: boolean()
  defp worktree_active_for_issue?({_path, issue_identifier}, active_issue_identifiers) do
    MapSet.member?(active_issue_identifiers, issue_identifier)
  end

  @spec remove_inactive_worktree?(String.t(), module(), keyword()) :: boolean()
  defp remove_inactive_worktree?(issue_identifier, tracker, tracker_opts) do
    case tracker.fetch_issue_by_identifier(issue_identifier, tracker_opts) do
      {:ok, nil} -> true
      {:ok, %Issue{} = issue} -> inactive_issue_state?(issue.state)
      {:error, _reason} -> false
    end
  end

  @spec remove_orphaned_worktree?(String.t(), String.t(), module(), keyword(), keyword()) ::
          boolean()
  defp remove_orphaned_worktree?(path, issue_identifier, tracker, tracker_opts, opts) do
    case tracker.fetch_issue_by_identifier(issue_identifier, tracker_opts) do
      {:ok, nil} ->
        true

      {:ok, %Issue{} = issue} ->
        inactive_issue_state?(issue.state) or stale_orphaned_worktree?(path, opts)

      {:error, _reason} ->
        false
    end
  end

  @spec stale_orphaned_worktree?(String.t(), keyword()) :: boolean()
  defp stale_orphaned_worktree?(path, opts) do
    ttl_ms = Keyword.get(opts, :stale_orphan_ttl_ms, @default_stale_orphan_ttl_ms)
    now_ms = System.system_time(:millisecond)

    case SessionStore.load(path) do
      {:ok, nil} ->
        stale_path_mtime?(path, ttl_ms, now_ms)

      {:ok, session} ->
        not SessionStore.recoverable?(session) and stale_session?(session, path, ttl_ms, now_ms)

      {:error, _reason} ->
        stale_path_mtime?(path, ttl_ms, now_ms)
    end
  end

  @spec stale_session?(SessionStore.session_data(), String.t(), non_neg_integer(), integer()) ::
          boolean()
  defp stale_session?(session, path, ttl_ms, now_ms) do
    case DateTime.from_iso8601(session.updated_at) do
      {:ok, updated_at, _offset} -> now_ms - DateTime.to_unix(updated_at, :millisecond) >= ttl_ms
      {:error, _reason} -> stale_path_mtime?(path, ttl_ms, now_ms)
    end
  end

  @spec stale_path_mtime?(String.t(), non_neg_integer(), integer()) :: boolean()
  defp stale_path_mtime?(path, ttl_ms, now_ms) do
    case File.stat(path, time: :posix) do
      {:ok, stat} -> now_ms - stat.mtime * 1000 >= ttl_ms
      {:error, _reason} -> false
    end
  end

  @spec inactive_issue_state?(String.t() | nil) :: boolean()
  defp inactive_issue_state?(state) when is_binary(state) do
    normalized = state |> String.trim() |> String.downcase()
    normalized in ["closed", "done"]
  end

  defp inactive_issue_state?(_state), do: false

  @spec cleanup_stale_worktree_path(String.t(), String.t(), String.t(), shell_fun()) ::
          :ok | {:error, term()}
  defp cleanup_stale_worktree_path(root, path, source_repo_path, shell) do
    with :ok <- ensure_within_root(root, path),
         {_, 0} <- shell.("git", ["worktree", "prune"], cd: source_repo_path) do
      active_paths = active_worktree_paths(source_repo_path, shell)
      remove_stale_path(path, active_paths)
    else
      {:error, _} = error -> error
      {output, code} when is_integer(code) -> {:error, {:git_failed, code, output}}
    end
  end

  @spec remove_stale_path(String.t(), [String.t()]) :: :ok | {:error, term()}
  defp remove_stale_path(path, active_paths) do
    cond do
      not File.exists?(path) ->
        :ok

      Path.expand(path) in active_paths ->
        {:error, {:worktree_path_already_active, path}}

      true ->
        remove_orphaned_path(path)
    end
  end

  @spec remove_orphaned_path(String.t()) :: :ok | {:error, term()}
  defp remove_orphaned_path(path) do
    case File.rm_rf(path) do
      {:ok, _removed} -> :ok
      {:error, reason, _file} -> {:error, {:stale_worktree_cleanup_failed, reason, path}}
    end
  end

  @spec active_worktree_paths(String.t(), shell_fun()) :: [String.t()]
  defp active_worktree_paths(source_repo_path, shell) do
    case shell.("git", ["worktree", "list", "--porcelain"], cd: source_repo_path) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn
          "worktree " <> listed_path -> [Path.expand(listed_path)]
          _other -> []
        end)

      {_output, _code} ->
        []
    end
  end

  @spec run_hook(atom(), keyword(), String.t(), shell_fun(), Issue.t() | nil) ::
          :ok | {:error, term()}
  defp run_hook(name, hooks, path, shell, issue) do
    case Keyword.get(hooks, name, "") do
      "" ->
        :ok

      command ->
        env = issue_env(path, issue)

        case shell.("bash", ["-lc", command], cd: path, env: env) do
          {_output, 0} -> :ok
          {output, code} -> {:error, {:hook_failed, name, code, output}}
        end
    end
  end

  @spec issue_env(String.t(), Issue.t() | nil) :: [{String.t(), String.t()}]
  defp issue_env(path, nil), do: [{"SYMPHONY_WORKSPACE_PATH", path}]

  defp issue_env(path, %Issue{} = issue) do
    [
      {"SYMPHONY_WORKSPACE_PATH", path},
      {"SYMPHONY_ISSUE_ID", issue.id},
      {"SYMPHONY_ISSUE_IDENTIFIER", issue.identifier},
      {"SYMPHONY_ISSUE_TITLE", issue.title}
    ]
  end
end
