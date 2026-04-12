defmodule SymphonyEx.Workspace do
  @moduledoc """
  Manages issue-scoped git worktrees under the configured workspace root.
  """

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.{SessionStore, SourceRepo}

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
         {_, 0} <-
           shell.("git", ["worktree", "add", "--detach", path, "HEAD"], cd: source_repo_path),
         :ok <- run_hook(:after_create, hooks, path, shell, issue) do
      {:ok, %{path: path, reason: reason}}
    else
      {:error, _} = error -> error
      {output, code} when is_integer(code) -> {:error, {:git_failed, code, output}}
    end
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
        case File.rm_rf(path) do
          {:ok, _removed} -> :ok
          {:error, reason, _file} -> {:error, {:stale_worktree_cleanup_failed, reason, path}}
        end
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
