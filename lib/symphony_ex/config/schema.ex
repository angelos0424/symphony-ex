defmodule SymphonyEx.Config.Schema do
  @moduledoc """
  Configuration schema and validation using NimbleOptions.
  Parses WORKFLOW.md YAML front matter and environment variables.
  """

  @lifecycle_state_schema [
    type: :keyword_list,
    default: [],
    keys: [
      issue_state: [type: :string],
      project_status: [type: :string],
      project_fields: [type: {:custom, __MODULE__, :validate_project_fields, []}]
    ]
  ]

  @lifecycle_release_schema [
    type: :keyword_list,
    default: [],
    keys: [
      success: @lifecycle_state_schema,
      failed: @lifecycle_state_schema,
      cancelled: @lifecycle_state_schema,
      any: @lifecycle_state_schema
    ]
  ]

  @write_back_state_schema [
    type: :keyword_list,
    default: [],
    keys: [
      labels: [type: {:list, :string}, default: []],
      assignees: [type: {:list, :string}, default: []]
    ]
  ]

  @write_back_release_schema [
    type: :keyword_list,
    default: [],
    keys: [
      success: @write_back_state_schema,
      failed: @write_back_state_schema,
      cancelled: @write_back_state_schema,
      any: @write_back_state_schema
    ]
  ]

  @lifecycle_schema [
    type: :keyword_list,
    default: [],
    keys: [
      claimed: @lifecycle_state_schema,
      running: @lifecycle_state_schema,
      retry_queued: @lifecycle_state_schema,
      released: @lifecycle_release_schema
    ]
  ]

  @schema NimbleOptions.new!(
            tracker: [
              type: :keyword_list,
              required: true,
              keys: [
                kind: [type: {:in, [:github]}, default: :github],
                endpoint: [type: :string, default: "https://api.github.com"],
                graphql_endpoint: [type: :string, default: "https://api.github.com/graphql"],
                api_key: [type: :string],
                owner: [type: :string],
                repo: [type: :string],
                project_number: [type: :pos_integer],
                active_states: [type: {:list, :string}, default: ["In Progress", "Todo"]],
                terminal_states: [type: {:list, :string}, default: ["Done", "Canceled"]],
                required_metadata_fields: [type: {:list, :atom}, default: [:service, :paths]],
                write_back: [
                  type: :keyword_list,
                  default: [],
                  keys: [
                    enabled: [type: :boolean, default: true],
                    in_progress_state_names: [type: {:list, :string}, default: ["In Progress"]],
                    review_state_names: [type: {:list, :string}, default: ["In Review"]],
                    labels: [type: {:list, :string}, default: []],
                    assignees: [type: {:list, :string}, default: []],
                    assignee_mode: [
                      type: {:or, [{:in, [:merge, :replace]}, {:in, ["merge", "replace"]}]},
                      default: :merge
                    ],
                    managed_labels: [type: {:list, :string}, default: []],
                    managed_label_prefixes: [type: {:list, :string}, default: []],
                    claimed: @write_back_state_schema,
                    running: @write_back_state_schema,
                    retry_queued: @write_back_state_schema,
                    released: @write_back_release_schema
                  ]
                ],
                lifecycle: @lifecycle_schema,
                include_issue_identifiers: [type: {:list, :string}, default: []]
              ]
            ],
            workspace: [
              type: :keyword_list,
              required: true,
              keys: [
                root: [type: :string],
                source_repo_path: [type: :string],
                source_repo_url: [type: :string],
                source_cache_root: [type: :string],
                symphony_repo_path: [type: :string, default: ""],
                hooks: [
                  type: :keyword_list,
                  default: [],
                  keys: [
                    after_create: [type: :string, default: ""],
                    before_run: [type: :string, default: ""],
                    after_run: [type: :string, default: ""],
                    before_remove: [type: :string, default: ""]
                  ]
                ]
              ]
            ],
            codex: [
              type: :keyword_list,
              default: [],
              keys: [
                command: [type: :string, default: "codex app-server"],
                approval_policy: [
                  type: {:in, [:on_request, :on_failure, :never]},
                  default: :never
                ],
                thread_sandbox: [type: :string, default: "workspaceWrite"],
                turn_timeout_ms: [type: :pos_integer, default: 3_600_000],
                read_timeout_ms: [type: :pos_integer, default: 5_000],
                stall_timeout_ms: [type: :pos_integer, default: 300_000]
              ]
            ],
            orchestrator: [
              type: :keyword_list,
              default: [],
              keys: [
                issue_identifier: [type: :string],
                poll_interval_ms: [type: :pos_integer, default: 30_000],
                max_concurrent: [type: :pos_integer, default: 1],
                max_retries: [type: :non_neg_integer, default: 3],
                backoff_base_ms: [type: :pos_integer, default: 60_000]
              ]
            ],
            logging: [
              type: :keyword_list,
              default: [],
              keys: [
                format: [type: {:in, [:pretty, :json]}, default: :pretty],
                level: [type: {:in, [:debug, :info, :warning, :error]}],
                metadata: [type: {:or, [{:list, :atom}, {:in, [:all]}]}, default: :all],
                redact_keys: [type: {:list, :atom}, default: []],
                max_metadata_value_length: [type: :pos_integer, default: 2_048]
              ]
            ],
            dashboard: [
              type: :keyword_list,
              default: [],
              keys: [
                enabled: [type: :boolean, default: false],
                port: [type: :pos_integer, default: 4000],
                host: [type: :string, default: "127.0.0.1"],
                secret_key_base: [type: :string]
              ]
            ]
          )

  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    opts = NimbleOptions.validate!(opts, @schema)

    opts
    |> validate_tracker_requirements!()
    |> validate_dashboard_requirements!()
  end

  @spec validate_tracker_requirements!(keyword()) :: keyword()
  defp validate_tracker_requirements!(opts) do
    tracker = Keyword.fetch!(opts, :tracker)
    kind = Keyword.get(tracker, :kind, :github)
    required_keys = [:api_key, :owner, :repo]

    missing_keys = Enum.filter(required_keys, &blank_tracker_value?(Keyword.get(tracker, &1)))

    if missing_keys == [] do
      opts
    else
      raise ArgumentError,
            "tracker kind #{inspect(kind)} requires #{Enum.map_join(missing_keys, ", ", &inspect/1)}"
    end
  end

  @spec blank_tracker_value?(term()) :: boolean()
  defp blank_tracker_value?(nil), do: true
  defp blank_tracker_value?(""), do: true
  defp blank_tracker_value?(_value), do: false

  @spec validate_dashboard_requirements!(keyword()) :: keyword()
  defp validate_dashboard_requirements!(opts) do
    dashboard = Keyword.get(opts, :dashboard, [])
    enabled = Keyword.get(dashboard, :enabled, false)
    secret_key_base = dashboard |> Keyword.get(:secret_key_base) |> normalize_optional_string()

    if enabled and is_nil(secret_key_base) do
      raise ArgumentError,
            "dashboard.secret_key_base is required when dashboard.enabled is true"
    end

    opts
  end

  @doc false
  @spec validate_project_fields(term()) :: {:ok, map() | keyword()} | {:error, String.t()}
  def validate_project_fields(value) when is_list(value) or is_map(value) do
    if Enum.all?(value, fn
         {_key, field_value} -> supported_project_field_value?(field_value)
         _other -> false
       end) do
      {:ok, value}
    else
      {:error, project_fields_error(value)}
    end
  end

  def validate_project_fields(value) do
    {:error, project_fields_error(value)}
  end

  @spec supported_project_field_value?(term()) :: boolean()
  defp supported_project_field_value?(value) when is_binary(value), do: true
  defp supported_project_field_value?(value) when is_number(value), do: true
  defp supported_project_field_value?(nil), do: true
  defp supported_project_field_value?(_value), do: false

  @spec project_fields_error(term()) :: String.t()
  defp project_fields_error(value) do
    "expected project_fields to be a map or keyword list containing only string, number, or nil values, got: #{inspect(value)}"
  end

  @spec normalize_optional_string(term()) :: String.t() | nil
  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_optional_string(_value), do: nil
end
