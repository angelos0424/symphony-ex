defmodule SymphonyEx.SourceRepo do
  @moduledoc """
  Resolves the canonical local source repository path used for git worktree operations.
  """

  @type shell_fun :: (String.t(), [String.t()], keyword() -> {binary(), non_neg_integer()})

  @spec resolve_workspace(keyword()) :: {:ok, keyword()} | {:error, term()}
  def resolve_workspace(workspace_opts) do
    shell = Keyword.get(workspace_opts, :shell_fun, &System.cmd/3)
    cwd = File.cwd!()
    root = expand_path(Keyword.get(workspace_opts, :root) || default_workspace_root(cwd), cwd)

    explicit_path = present_string(Keyword.get(workspace_opts, :source_repo_path))
    source_repo_url = present_string(Keyword.get(workspace_opts, :source_repo_url))

    source_cache_root =
      expand_path(
        Keyword.get(workspace_opts, :source_cache_root) || default_source_cache_root(cwd),
        cwd
      )

    with {:ok, resolved_path, extras} <-
           resolve_source_repo(explicit_path, source_repo_url, source_cache_root, shell, cwd) do
      workspace_opts
      |> Keyword.put(:root, root)
      |> Keyword.put(:source_repo_path, resolved_path)
      |> maybe_put(:source_cache_root, extras[:source_cache_root])
      |> maybe_put(:source_repo_url, extras[:source_repo_url])
      |> then(&{:ok, &1})
    end
  end

  @spec resolve_workspace!(keyword()) :: keyword()
  def resolve_workspace!(workspace_opts) do
    case resolve_workspace(workspace_opts) do
      {:ok, resolved} -> resolved
      {:error, reason} -> raise ArgumentError, format_error(reason)
    end
  end

  defp resolve_source_repo(explicit_path, source_repo_url, source_cache_root, _shell, cwd)
       when is_binary(explicit_path) do
    path = expand_path(explicit_path, cwd)
    {:ok, path, [source_repo_url: source_repo_url, source_cache_root: source_cache_root]}
  end

  defp resolve_source_repo(nil, source_repo_url, source_cache_root, shell, _cwd)
       when is_binary(source_repo_url) do
    cache_dir = cache_dir_name_from_url(source_repo_url)
    path = Path.join(source_cache_root, cache_dir)

    with :ok <- ensure_directory(source_cache_root, :source_cache_root),
         :ok <- ensure_repo_bootstrapped(path, source_repo_url, shell),
         :ok <- validate_local_git_repo(path, shell) do
      {:ok, path, [source_repo_url: source_repo_url, source_cache_root: source_cache_root]}
    end
  end

  defp resolve_source_repo(nil, nil, _source_cache_root, _shell, _cwd) do
    {:error, :missing_source_repo}
  end

  defp ensure_repo_bootstrapped(path, source_repo_url, shell) do
    cond do
      File.exists?(path) and not File.dir?(path) ->
        {:error, {:source_repo_cache_not_directory, path}}

      File.exists?(path) ->
        with :ok <- validate_local_git_repo(path, shell),
             :ok <- validate_remote_match(path, source_repo_url, shell),
             :ok <- git(path, ["fetch", "--all", "--prune"], shell),
             :ok <- align_cached_repo_head(path, shell) do
          :ok
        end

      true ->
        case File.mkdir_p(Path.dirname(path)) do
          :ok ->
            with :ok <- git(nil, ["clone", source_repo_url, path], shell),
                 :ok <- align_cached_repo_head(path, shell) do
              :ok
            end

          {:error, reason} ->
            {:error, {:source_repo_clone_parent_unwritable, Path.dirname(path), reason}}
        end
    end
  end

  defp validate_remote_match(path, source_repo_url, shell) do
    case shell.("git", ["remote", "get-url", "origin"], cd: path) do
      {output, 0} ->
        remote_url = String.trim(output)

        if canonical_repo_identity(remote_url) == canonical_repo_identity(source_repo_url) do
          :ok
        else
          {:error, {:source_repo_remote_mismatch, path, remote_url, source_repo_url}}
        end

      {output, code} ->
        {:error, {:git_failed, code, String.trim(output), path}}
    end
  end

  defp align_cached_repo_head(path, shell) do
    with :ok <- git(path, ["remote", "set-head", "origin", "--auto"], shell),
         {:ok, base_ref} <- origin_head_ref(path, shell),
         :ok <- git(path, ["checkout", "--detach", base_ref], shell) do
      :ok
    end
  end

  defp origin_head_ref(path, shell) do
    case shell.("git", ["symbolic-ref", "refs/remotes/origin/HEAD"], cd: path) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:git_failed, code, String.trim(output), path}}
    end
  end

  defp validate_local_git_repo(path, shell) do
    cond do
      not File.dir?(path) ->
        {:error, {:source_repo_path_missing, path}}

      true ->
        case shell.("git", ["rev-parse", "--is-inside-work-tree"], cd: path) do
          {output, 0} ->
            if String.trim(output) == "true" do
              :ok
            else
              {:error, {:source_repo_not_git_repo, path}}
            end

          {_output, _code} ->
            {:error, {:source_repo_not_git_repo, path}}
        end
    end
  end

  defp git(nil, args, shell) do
    case shell.("git", args, []) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:git_failed, code, String.trim(output), nil}}
    end
  end

  defp git(path, args, shell) do
    case shell.("git", args, cd: path) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:git_failed, code, String.trim(output), path}}
    end
  end

  defp ensure_directory(path, label) do
    case File.mkdir_p(path) do
      :ok -> :ok
      {:error, reason} -> {:error, {label, :mkdir_failed, path, reason}}
    end
  end

  defp cache_dir_name_from_url(url) do
    case canonical_repo_identity(url) do
      {:github_like, host, owner, repo} ->
        Enum.join([host, owner, repo], "__")

      {:generic, normalized} ->
        normalized
        |> :erlang.md5()
        |> Base.encode16(case: :lower)
    end
  end

  defp canonical_repo_identity(url) do
    trimmed = String.trim(url)

    with {:ok, parsed} <- parse_github_like_url(trimmed) do
      parsed
    else
      _ -> {:generic, trimmed |> String.trim_trailing("/") |> String.replace_suffix(".git", "")}
    end
  end

  defp parse_github_like_url(url) do
    cond do
      String.match?(url, ~r/^[^@\s]+@[^:]+:.+$/) ->
        [user_host, repo_path] = String.split(url, ":", parts: 2)
        [_user, host] = String.split(user_host, "@", parts: 2)
        github_like_identity(host, repo_path)

      true ->
        case URI.parse(url) do
          %URI{host: host, path: path} when is_binary(host) and is_binary(path) ->
            github_like_identity(host, path)

          _ ->
            :error
        end
    end
  end

  defp github_like_identity(host, repo_path) do
    segments =
      repo_path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")
      |> String.replace_suffix(".git", "")
      |> String.split("/", trim: true)

    case segments do
      [owner, repo] when owner != "" and repo != "" ->
        {:ok,
         {:github_like, String.downcase(host), String.downcase(owner), String.downcase(repo)}}

      _ ->
        :error
    end
  end

  defp default_workspace_root(cwd), do: Path.join([cwd, ".symphony", "worktrees"])
  defp default_source_cache_root(cwd), do: Path.join([cwd, ".symphony", "source-cache"])

  defp expand_path(path, cwd), do: path |> Path.expand(cwd)

  defp present_string(nil), do: nil

  defp present_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp format_error(:missing_source_repo) do
    "workspace.source_repo_path or SOURCE_REPO_PATH must be set, or provide workspace.source_repo_url / SOURCE_REPO_URL for auto-bootstrap"
  end

  defp format_error({:source_cache_root, :mkdir_failed, path, reason}) do
    "unable to create SOURCE_CACHE_ROOT at #{path}: #{inspect(reason)}"
  end

  defp format_error({:source_repo_path_missing, path}),
    do: "source repo path does not exist: #{path}"

  defp format_error({:source_repo_not_git_repo, path}),
    do: "source repo path is not a git work tree: #{path}"

  defp format_error({:source_repo_cache_not_directory, path}) do
    "source repo cache path exists but is not a directory: #{path}"
  end

  defp format_error({:source_repo_remote_mismatch, path, actual, expected}) do
    "cached source repo remote mismatch at #{path}: origin=#{inspect(actual)} configured=#{inspect(expected)}"
  end

  defp format_error({:source_repo_clone_parent_unwritable, path, reason}) do
    "unable to prepare source repo cache directory #{path}: #{inspect(reason)}"
  end

  defp format_error({:git_failed, code, output, nil}) do
    "git command failed with exit #{code}: #{output}"
  end

  defp format_error({:git_failed, code, output, path}) do
    "git command failed with exit #{code} in #{path}: #{output}"
  end

  defp format_error(other), do: inspect(other)
end
