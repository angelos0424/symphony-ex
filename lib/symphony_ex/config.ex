defmodule SymphonyEx.Config do
  @moduledoc """
  Loads configuration from WORKFLOW.md YAML front matter and environment variables.
  """

  alias SymphonyEx.Config.Schema
  alias SymphonyEx.Orchestrator.Lifecycle
  alias SymphonyEx.SourceRepo

  @spec load!(String.t()) :: keyword()
  def load!(workflow_path) do
    yaml = parse_front_matter!(workflow_path)
    env = load_env(yaml)

    yaml
    |> deep_merge(env)
    |> Schema.validate!()
    |> normalize_runtime_structs()
  end

  @spec load(String.t()) :: {:ok, keyword()} | {:error, term()}
  def load(workflow_path) do
    with {:ok, content} <- File.read(workflow_path),
         {:ok, yaml} <- parse_front_matter(content),
         {:ok, validated} <- validate(yaml) do
      {:ok, validated}
    end
  end

  @spec parse_front_matter(String.t()) :: {:ok, keyword()} | {:error, term()}
  defp parse_front_matter(content) do
    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, yaml_str] ->
        case YamlElixir.read_from_string(yaml_str) do
          {:ok, map} -> {:ok, normalize_yaml(map)}
          {:error, _} = err -> err
        end

      nil ->
        {:ok, []}
    end
  end

  @spec validate(keyword()) :: {:ok, keyword()} | {:error, term()}
  defp validate(yaml) do
    try do
      env = load_env(yaml)
      merged = deep_merge(yaml, env)

      case NimbleOptions.validate(merged, Schema.schema()) do
        {:ok, validated} ->
          with {:ok, validated} <- validate_tracker_requirements(validated) do
            {:ok, normalize_runtime_structs(validated)}
          end

        {:error, _} = err ->
          err
      end
    rescue
      error in [ArgumentError] -> {:error, error}
    end
  end

  @spec validate_tracker_requirements(keyword()) :: {:ok, keyword()} | {:error, term()}
  defp validate_tracker_requirements(opts) do
    tracker = Keyword.fetch!(opts, :tracker)
    kind = Keyword.get(tracker, :kind, :github)
    required_keys = [:api_key, :owner, :repo]

    missing_keys =
      Enum.filter(required_keys, fn key ->
        value = Keyword.get(tracker, key)
        value == nil or value == ""
      end)

    cond do
      missing_keys != [] ->
        {:error, {:missing_tracker_keys, kind, Enum.map_join(missing_keys, ", ", &inspect/1)}}

      dashboard_secret_required?(opts) ->
        {:error,
         ArgumentError.exception(
           "dashboard.secret_key_base is required when dashboard.enabled is true"
         )}

      true ->
        {:ok, opts}
    end
  end

  @spec dashboard_secret_required?(keyword()) :: boolean()
  defp dashboard_secret_required?(opts) do
    dashboard = Keyword.get(opts, :dashboard, [])
    enabled = Keyword.get(dashboard, :enabled, false)
    secret_key_base = dashboard |> Keyword.get(:secret_key_base) |> normalize_optional_string()

    enabled and is_nil(secret_key_base)
  end

  @spec normalize_optional_string(term()) :: String.t() | nil
  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil

  @spec parse_front_matter!(String.t()) :: keyword()
  def parse_front_matter!(path) do
    content = File.read!(path)

    case Regex.run(~r/\A---\n(.*?)\n---/s, content) do
      [_, yaml_str] ->
        yaml_str
        |> YamlElixir.read_from_string!()
        |> normalize_yaml()

      nil ->
        []
    end
  end

  @spec load_env(keyword()) :: keyword()
  def load_env(yaml \\ []) do
    tracker_env = load_tracker_env(yaml)
    workspace_env = load_workspace_env()
    orchestrator_env = load_orchestrator_env()
    logging_env = load_logging_env()
    dashboard_env = load_dashboard_env()

    []
    |> maybe_put(:tracker, tracker_env)
    |> maybe_put(:workspace, workspace_env)
    |> maybe_put(:orchestrator, orchestrator_env)
    |> maybe_put(:logging, logging_env)
    |> maybe_put(:dashboard, dashboard_env)
  end

  @spec load_tracker_env(keyword()) :: keyword()
  defp load_tracker_env(yaml) do
    github_env = github_tracker_env()
    explicit_kind = env_atom("TRACKER_KIND")
    yaml_kind = yaml |> Keyword.get(:tracker, []) |> Keyword.get(:kind)

    resolve_tracker_env(explicit_kind, yaml_kind, github_env)
  end

  @spec resolve_tracker_env(atom() | nil, atom() | nil, keyword()) :: keyword()
  defp resolve_tracker_env(:github, _yaml_kind, github_env), do: github_env
  defp resolve_tracker_env(_explicit, :github, github_env) when github_env != [], do: github_env

  defp resolve_tracker_env(_explicit, _yaml_kind, github_env) when github_env != [],
    do: github_env

  defp resolve_tracker_env(_explicit, _yaml_kind, _github_env), do: []

  @spec github_tracker_env() :: keyword()
  defp github_tracker_env do
    []
    |> maybe_put(:kind, env_atom("TRACKER_KIND"))
    |> maybe_put(:api_key, System.get_env("GITHUB_TOKEN"))
    |> maybe_put(:owner, System.get_env("GITHUB_OWNER"))
    |> maybe_put(:repo, System.get_env("GITHUB_REPO"))
    |> maybe_put(:project_number, env_integer("GITHUB_PROJECT_NUMBER"))
    |> maybe_put(:endpoint, System.get_env("GITHUB_API_URL"))
    |> maybe_put(:graphql_endpoint, System.get_env("GITHUB_GRAPHQL_URL"))
    |> normalize_tracker_kind(:github)
  end

  @spec normalize_tracker_kind(keyword(), :github) :: keyword()
  defp normalize_tracker_kind(tracker_env, default_kind) do
    kind = Keyword.get(tracker_env, :kind)

    cond do
      tracker_env == [] -> []
      kind in [nil, default_kind] -> maybe_put(tracker_env, :kind, default_kind)
      true -> tracker_env
    end
  end

  @spec normalize_runtime_structs(keyword()) :: keyword()
  defp normalize_runtime_structs(opts) do
    opts
    |> normalize_tracker_runtime_structs()
    |> normalize_logging_runtime_structs()
    |> normalize_workspace_runtime_structs()
  end

  @spec normalize_workspace_runtime_structs(keyword()) :: keyword()
  defp normalize_workspace_runtime_structs(opts) do
    workspace_opts = Keyword.get(opts, :workspace, [])
    Keyword.put(opts, :workspace, SourceRepo.resolve_workspace!(workspace_opts))
  end

  @spec normalize_tracker_runtime_structs(keyword()) :: keyword()
  defp normalize_tracker_runtime_structs(opts) do
    tracker = Keyword.get(opts, :tracker, [])

    case Keyword.get(tracker, :lifecycle) do
      lifecycle_opts when is_list(lifecycle_opts) ->
        lifecycle = lifecycle_from_config(lifecycle_opts)

        if lifecycle == Lifecycle.default() do
          opts
        else
          Keyword.put(opts, :tracker, Keyword.put(tracker, :lifecycle, lifecycle))
        end

      _other ->
        opts
    end
  end

  @spec normalize_logging_runtime_structs(keyword()) :: keyword()
  defp normalize_logging_runtime_structs(opts) do
    case Keyword.get(opts, :logging) do
      logging_opts when is_list(logging_opts) ->
        normalized =
          logging_opts
          |> Keyword.update(:format, :pretty, &normalize_log_atom/1)
          |> maybe_update(:level, &normalize_log_atom/1)
          |> maybe_update(:metadata, &normalize_metadata_keys/1)
          |> maybe_update(:redact_keys, &normalize_metadata_keys_list/1)

        Keyword.put(opts, :logging, normalized)

      _other ->
        opts
    end
  end

  @spec lifecycle_from_config(keyword()) :: Lifecycle.t()
  def lifecycle_from_config(opts) do
    issue_state_mapping =
      opts
      |> issue_state_entries()
      |> Map.new()

    project_status_mapping =
      opts
      |> project_status_entries()
      |> Map.new()

    project_field_mapping =
      opts
      |> project_field_entries()
      |> Map.new()

    Lifecycle.new(
      issue_state_mapping: issue_state_mapping,
      project_status_mapping: project_status_mapping,
      project_field_mapping: project_field_mapping
    )
  end

  @spec issue_state_entries(keyword()) :: [{{atom(), atom()}, :open | :closed}]
  defp issue_state_entries(opts) do
    run_state_entries(opts, :claimed) ++
      run_state_entries(opts, :running) ++
      run_state_entries(opts, :retry_queued) ++
      release_entries(opts, :issue_state)
  end

  @spec project_status_entries(keyword()) :: [{{atom(), atom()}, String.t()}]
  defp project_status_entries(opts) do
    run_state_entries(opts, :claimed, :project_status) ++
      run_state_entries(opts, :running, :project_status) ++
      run_state_entries(opts, :retry_queued, :project_status) ++
      release_entries(opts, :project_status)
  end

  @spec project_field_entries(keyword()) :: [{{atom(), atom()}, map()}]
  defp project_field_entries(opts) do
    run_state_entries(opts, :claimed, :project_fields) ++
      run_state_entries(opts, :running, :project_fields) ++
      run_state_entries(opts, :retry_queued, :project_fields) ++
      release_entries(opts, :project_fields)
  end

  @spec run_state_entries(keyword(), atom(), atom()) :: [{{atom(), atom()}, term()}]
  defp run_state_entries(opts, run_state, key \\ :issue_state) do
    opts
    |> Keyword.get(run_state, [])
    |> value_entry(run_state, :any, key)
    |> List.wrap()
  end

  @spec release_entries(keyword(), atom()) :: [{{atom(), atom()}, term()}]
  defp release_entries(opts, key) do
    opts
    |> Keyword.get(:released, [])
    |> List.wrap()
    |> Enum.flat_map(fn {result, result_opts} ->
      value_entry(result_opts, :released, result, key)
      |> List.wrap()
    end)
  end

  @spec value_entry(keyword(), atom(), atom(), atom()) :: {{atom(), atom()}, term()} | nil
  defp value_entry(opts, run_state, result, key) do
    case Keyword.get(opts || [], key) do
      nil -> nil
      value when key == :issue_state -> {{run_state, result}, normalize_issue_state(value)}
      value when key == :project_fields -> {{run_state, result}, normalize_project_fields(value)}
      value -> {{run_state, result}, value}
    end
  end

  @spec normalize_project_fields(term()) :: map()
  defp normalize_project_fields(value) when is_list(value) do
    value
    |> Enum.map(fn {key, field_value} -> {to_string(key), field_value} end)
    |> Map.new()
  end

  defp normalize_project_fields(value) when is_map(value) do
    value
    |> Enum.map(fn {key, field_value} -> {to_string(key), field_value} end)
    |> Map.new()
  end

  defp normalize_project_fields(_value), do: %{}

  @spec normalize_issue_state(String.t() | atom()) :: :open | :closed
  defp normalize_issue_state(value) when is_atom(value), do: value

  defp normalize_issue_state(value) do
    case value |> to_string() |> String.trim() |> String.downcase() do
      "closed" -> :closed
      _ -> :open
    end
  end

  @spec load_workspace_env() :: keyword()
  defp load_workspace_env do
    []
    |> maybe_put(:root, System.get_env("WORKSPACE_ROOT"))
    |> maybe_put(:source_repo_path, System.get_env("SOURCE_REPO_PATH"))
    |> maybe_put(:source_repo_url, System.get_env("SOURCE_REPO_URL"))
    |> maybe_put(:source_cache_root, System.get_env("SOURCE_CACHE_ROOT"))
    |> maybe_put(:symphony_repo_path, System.get_env("SYMPHONY_REPO_PATH"))
  end

  @spec load_orchestrator_env() :: keyword()
  defp load_orchestrator_env do
    []
    |> maybe_put(:issue_identifier, env_issue_identifier())
  end

  @spec load_logging_env() :: keyword()
  defp load_logging_env do
    []
    |> maybe_put(:format, env_atom("SYMPHONY_LOG_FORMAT") || env_atom("LOG_FORMAT"))
    |> maybe_put(:level, env_atom("SYMPHONY_LOG_LEVEL") || env_atom("LOG_LEVEL"))
    |> maybe_put(:metadata, env_metadata_list("SYMPHONY_LOG_METADATA"))
    |> maybe_put(:redact_keys, env_metadata_keys_list("SYMPHONY_LOG_REDACT_KEYS"))
    |> maybe_put(
      :max_metadata_value_length,
      env_integer("SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH")
    )
  end

  @spec load_dashboard_env() :: keyword()
  defp load_dashboard_env do
    []
    |> maybe_put(:enabled, env_boolean("SYMPHONY_DASHBOARD_ENABLED"))
    |> maybe_put(:port, env_integer("SYMPHONY_DASHBOARD_PORT"))
    |> maybe_put(:host, System.get_env("SYMPHONY_DASHBOARD_HOST"))
    |> maybe_put(:secret_key_base, System.get_env("SYMPHONY_DASHBOARD_SECRET_KEY_BASE"))
  end

  @spec env_boolean(String.t()) :: boolean() | nil
  defp env_boolean(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      "true" -> true
      "false" -> false
      _other -> nil
    end
  end

  @spec env_issue_identifier() :: String.t() | nil
  defp env_issue_identifier do
    System.get_env("GITHUB_ISSUE_IDENTIFIER") || System.get_env("ISSUE_IDENTIFIER")
  end

  @spec maybe_put(keyword(), atom(), term()) :: keyword()
  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  @spec env_integer(String.t()) :: integer() | nil
  defp env_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      "" ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} -> integer
          _ -> raise ArgumentError, "invalid integer env #{name}=#{inspect(value)}"
        end
    end
  end

  @spec env_atom(String.t()) :: atom() | nil
  defp env_atom(name) do
    case System.get_env(name) do
      nil ->
        nil

      "" ->
        nil

      value ->
        normalize_log_atom(value)
    end
  end

  @spec env_metadata_list(String.t()) :: [atom()] | :all | nil
  defp env_metadata_list(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> normalize_metadata_keys(value)
    end
  end

  @spec env_metadata_keys_list(String.t()) :: [atom()] | nil
  defp env_metadata_keys_list(name) do
    case System.get_env(name) do
      nil -> nil
      "" -> nil
      value -> normalize_metadata_keys_list(value)
    end
  end

  @spec normalize_yaml(map()) :: keyword()
  defp normalize_yaml(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} ->
      normalized_key = normalize_key(k)

      normalized_value =
        if normalized_key == :project_fields,
          do: normalize_project_field_value(v),
          else: normalize_yaml(v)

      {normalized_key, normalized_value}
    end)
  end

  defp normalize_yaml(list) when is_list(list), do: Enum.map(list, &normalize_yaml/1)

  @yaml_atom_literals %{
    "github" => :github,
    "pretty" => :pretty,
    "json" => :json,
    "debug" => :debug,
    "info" => :info,
    "warning" => :warning,
    "error" => :error,
    "merge" => :merge,
    "replace" => :replace
  }

  defp normalize_yaml(value) when is_binary(value) do
    trimmed =
      value
      |> String.trim()
      |> maybe_expand_env_placeholder()

    Map.get(@yaml_atom_literals, trimmed, trimmed)
  end

  defp normalize_yaml(value), do: value

  defp normalize_project_field_value(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_project_field_value(value)} end)
    |> Map.new()
  end

  defp normalize_project_field_value(list) when is_list(list) do
    Enum.map(list, &normalize_project_field_value/1)
  end

  defp normalize_project_field_value(value), do: normalize_yaml(value)

  @spec normalize_key(String.t() | atom()) :: atom()
  defp normalize_key(key) when is_binary(key) do
    Code.ensure_loaded!(Schema)

    key
    |> String.replace("-", "_")
    |> existing_atom!()
  end

  defp normalize_key(key) when is_atom(key), do: key

  @spec maybe_expand_env_placeholder(String.t()) :: String.t()
  defp maybe_expand_env_placeholder("$" <> env_name) do
    System.get_env(env_name) || "$" <> env_name
  end

  defp maybe_expand_env_placeholder(value), do: value

  @spec normalize_log_atom(String.t() | atom()) :: atom()
  defp normalize_log_atom(value) when is_atom(value), do: value

  defp normalize_log_atom(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> existing_atom!()
  end

  @spec existing_atom!(String.t()) :: atom()
  defp existing_atom!(value) do
    try do
      String.to_existing_atom(value)
    rescue
      ArgumentError -> raise ArgumentError, "unknown atom value #{inspect(value)} in config"
    end
  end

  @spec normalize_metadata_keys(String.t() | [String.t() | atom()] | atom()) :: [atom()] | :all
  defp normalize_metadata_keys(:all), do: :all

  defp normalize_metadata_keys(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_metadata_keys()
  end

  defp normalize_metadata_keys(values) when is_list(values) do
    if Enum.any?(values, &(to_string(&1) == "all")) do
      :all
    else
      Enum.map(values, &normalize_log_atom/1)
    end
  end

  defp normalize_metadata_keys(value), do: [normalize_log_atom(value)]

  @spec normalize_metadata_keys_list(String.t() | [String.t() | atom()] | atom()) :: [atom()]
  defp normalize_metadata_keys_list(:all), do: []

  defp normalize_metadata_keys_list(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> normalize_metadata_keys_list()
  end

  defp normalize_metadata_keys_list(values) when is_list(values) do
    values
    |> Enum.reject(&(to_string(&1) == "all"))
    |> Enum.map(&normalize_log_atom/1)
  end

  defp normalize_metadata_keys_list(value), do: [normalize_log_atom(value)]

  @spec maybe_update(keyword(), atom(), (term() -> term())) :: keyword()
  defp maybe_update(opts, key, fun) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> Keyword.put(opts, key, fun.(value))
      :error -> opts
    end
  end

  @spec deep_merge(keyword(), keyword()) :: keyword()
  defp deep_merge(left, right) do
    Keyword.merge(left, right, fn _key, v1, v2 ->
      if Keyword.keyword?(v1) and Keyword.keyword?(v2) do
        deep_merge(v1, v2)
      else
        v2
      end
    end)
  end
end
