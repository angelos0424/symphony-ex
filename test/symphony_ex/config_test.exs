defmodule SymphonyEx.ConfigTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Config
  alias SymphonyEx.Orchestrator.Lifecycle

  describe "load!/1" do
    test "loads GitHub tracker settings from env and workflow front matter" do
      workflow = """
      ---
      tracker:
        active-states:
          - Todo
          - In Progress
      workspace:
        root: /yaml/worktrees
      codex:
        command: codex app-server --stdio
      ---

      # Workflow
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"GITHUB_OWNER", "openai"},
          {"GITHUB_REPO", "symphony"},
          {"GITHUB_PROJECT_NUMBER", "7"},
          {"WORKSPACE_ROOT", "/env/worktrees"},
          {"SOURCE_REPO_PATH", "/repos/source"}
        ],
        fn ->
          config = Config.load!(path)

          assert config[:tracker][:kind] == :github
          assert config[:tracker][:api_key] == "ghs_test"
          assert config[:tracker][:owner] == "openai"
          assert config[:tracker][:repo] == "symphony"
          assert config[:tracker][:project_number] == 7
          assert config[:tracker][:active_states] == ["Todo", "In Progress"]
          assert config[:workspace][:root] == "/env/worktrees"
          assert config[:workspace][:source_repo_path] == "/repos/source"
          assert config[:codex][:command] == "codex app-server --stdio"
        end
      )
    end

    test "parses tracker lifecycle config into runtime lifecycle mappings" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
        lifecycle:
          claimed:
            issue-state: open
            project-status: In Progress
            project-fields:
              Owner: Codex
              ETA: $TARGET_ETA
              Estimate: 2
              Ready: null
          retry-queued:
            issue-state: open
            project-status: Blocked
          released:
            success:
              issue-state: closed
              project-status: Done
            failed:
              issue-state: open
              project-status: Todo
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"TARGET_ETA", "2026-04-01"}
        ],
        fn ->
          config = Config.load!(path)
          assert %Lifecycle{} = lifecycle = config[:tracker][:lifecycle]

          assert Lifecycle.resolve_issue_state(lifecycle, :claimed, nil) == :open
          assert Lifecycle.resolve_project_status(lifecycle, :claimed, nil) == "In Progress"

          assert Lifecycle.resolve_project_fields(lifecycle, :claimed, nil) == %{
                   "Owner" => "Codex",
                   "ETA" => "2026-04-01",
                   "Estimate" => 2,
                   "Ready" => nil
                 }

          assert Lifecycle.resolve_project_status(lifecycle, :retry_queued, nil) == "Blocked"
          assert Lifecycle.resolve_issue_state(lifecycle, :released, :success) == :closed
          assert Lifecycle.resolve_project_status(lifecycle, :released, :success) == "Done"
          assert Lifecycle.resolve_issue_state(lifecycle, :released, :failed) == :open
          assert Lifecycle.resolve_project_status(lifecycle, :released, :failed) == "Todo"

          assert Lifecycle.resolve_issue_state(lifecycle, :running, nil) == :open
          assert Lifecycle.resolve_project_status(lifecycle, :running, nil) == "In Progress"
        end
      )
    end

    test "returns an error when lifecycle project_fields contain nested values" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
        lifecycle:
          claimed:
            project-fields:
              Owner: Codex
              metadata:
                status: nested
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      ---
      """

      path = write_workflow!(workflow)

      with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
        assert {:error, error} = Config.load(path)

        assert Exception.message(error) =~ "project_fields"
        assert Exception.message(error) =~ "string, number, or nil values"
        assert Exception.message(error) =~ "metadata"
      end)
    end

    test "parses tracker write-back automation config" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
        write-back:
          labels:
            - symphony
          assignee-mode: replace
          claimed:
            labels:
              - symphony:claimed
            assignees:
              - codex-bot
          released:
            success:
              labels:
                - symphony:done
              assignees:
                - reviewer-bot
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      ---
      """

      path = write_workflow!(workflow)

      with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
        config = Config.load!(path)
        write_back = config[:tracker][:write_back]

        assert write_back[:labels] == ["symphony"]
        assert write_back[:assignee_mode] == :replace
        assert write_back[:review_state_names] == ["In Review"]
        assert write_back[:claimed][:labels] == ["symphony:claimed"]
        assert write_back[:claimed][:assignees] == ["codex-bot"]
        assert write_back[:released][:success][:labels] == ["symphony:done"]
        assert write_back[:released][:success][:assignees] == ["reviewer-bot"]
      end)
    end

    test "loads explicit issue identifier into orchestrator config" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      orchestrator:
        issue-identifier: "#42"
      ---
      """

      path = write_workflow!(workflow)

      with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
        config = Config.load!(path)
        assert config[:orchestrator][:issue_identifier] == "#42"
      end)
    end

    test "env issue identifier overrides workflow orchestrator issue identifier" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      orchestrator:
        issue-identifier: "#42"
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"GITHUB_ISSUE_IDENTIFIER", "#77"}
        ],
        fn ->
          config = Config.load!(path)
          assert config[:orchestrator][:issue_identifier] == "#77"
        end
      )
    end

    test "loads logging config from workflow and env overrides" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      logging:
        format: pretty
        metadata:
          - issue_id
          - outcome_kind
        redact_keys:
          - authorization
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"SYMPHONY_LOG_FORMAT", "json"},
          {"SYMPHONY_LOG_LEVEL", "debug"},
          {"SYMPHONY_LOG_METADATA", "issue_identifier,thread_id,recovered"},
          {"SYMPHONY_LOG_REDACT_KEYS", "api_key,token"},
          {"SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH", "512"}
        ],
        fn ->
          config = Config.load!(path)

          assert config[:logging][:format] == :json
          assert config[:logging][:level] == :debug
          assert config[:logging][:metadata] == [:issue_identifier, :thread_id, :recovered]
          assert config[:logging][:redact_keys] == [:api_key, :token]
          assert config[:logging][:max_metadata_value_length] == 512
        end
      )
    end

    test "requires dashboard secret_key_base when dashboard is enabled" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      dashboard:
        enabled: true
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"}
        ],
        fn ->
          assert {:error, error} = Config.load(path)
          assert Exception.message(error) =~ "dashboard.secret_key_base is required"
        end
      )
    end

    test "loads dashboard secret_key_base from env when dashboard is enabled" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      dashboard:
        enabled: true
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"SYMPHONY_DASHBOARD_SECRET_KEY_BASE", "test-dashboard-secret-key-base"}
        ],
        fn ->
          config = Config.load!(path)

          assert config[:dashboard][:enabled] == true
          assert config[:dashboard][:secret_key_base] == "test-dashboard-secret-key-base"
        end
      )
    end

    test "resolves SOURCE_REPO_URL into a canonical cached source repo path" do
      remote = git_fixture_repo!("source-repo-url")

      cache_root =
        Path.join(System.tmp_dir!(), "source-cache-#{System.unique_integer([:positive])}")

      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        source_repo_url: #{remote}
        source_cache_root: #{cache_root}
      ---
      """

      path = write_workflow!(workflow)

      with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
        assert {:ok, config} = Config.load(path)
        assert config[:workspace][:root] == Path.expand(".symphony/worktrees", File.cwd!())

        assert config[:workspace][:source_repo_path] ==
                 Path.join(cache_root, expected_cache_dir_for(remote))
      end)
    end

    test "loading config with SOURCE_REPO_URL stays side-effect free" do
      cache_root =
        Path.join(System.tmp_dir!(), "source-cache-#{System.unique_integer([:positive])}")

      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        source_repo_url: https://github.com/example/project.git
        source_cache_root: #{cache_root}
      ---
      """

      path = write_workflow!(workflow)
      expected_path = Path.join(cache_root, "github.com__example__project")

      with_env([{"GITHUB_TOKEN", "ghs_test"}], fn ->
        assert {:ok, config} = Config.load(path)
        assert config[:workspace][:source_repo_path] == expected_path
        refute File.exists?(expected_path)
      end)
    end

    test "SOURCE_REPO_PATH from env wins over SOURCE_REPO_URL" do
      explicit_repo = git_fixture_repo!("explicit-source")
      remote = git_fixture_repo!("ignored-remote")

      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        source_repo_url: #{remote}
        source_cache_root: /tmp/ignored-cache
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"SOURCE_REPO_PATH", explicit_repo}
        ],
        fn ->
          assert {:ok, config} = Config.load(path)
          assert config[:workspace][:source_repo_path] == explicit_repo
        end
      )
    end

    test "returns a clean error for invalid integer env values" do
      workflow = """
      ---
      tracker:
        owner: openai
        repo: symphony
      workspace:
        root: /tmp/worktrees
        source_repo_path: /tmp/source
      ---
      """

      path = write_workflow!(workflow)

      with_env(
        [
          {"GITHUB_TOKEN", "ghs_test"},
          {"GITHUB_PROJECT_NUMBER", "not-a-number"}
        ],
        fn ->
          assert {:error, error} = Config.load(path)
          assert Exception.message(error) =~ "invalid integer env GITHUB_PROJECT_NUMBER"
        end
      )
    end
  end

  defp write_workflow!(contents) do
    path = Path.join(System.tmp_dir!(), "workflow-#{System.unique_integer([:positive])}.md")
    File.write!(path, contents)
    path
  end

  defp git_fixture_repo!(name) do
    root = Path.join(System.tmp_dir!(), "#{name}-#{tmp_suffix()}")
    File.mkdir_p!(root)
    File.write!(Path.join(root, "README.md"), "# fixture\n")
    {_, 0} = System.cmd("git", ["init", "-b", "main"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test User"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@example.com"], cd: root)
    {_, 0} = System.cmd("git", ["add", "README.md"], cd: root)
    {_, 0} = System.cmd("git", ["commit", "-m", "init"], cd: root)
    root
  end

  defp tmp_suffix do
    Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end

  @tracked_env_vars [
    "TRACKER_KIND",
    "GITHUB_TOKEN",
    "GITHUB_OWNER",
    "GITHUB_REPO",
    "GITHUB_PROJECT_NUMBER",
    "GITHUB_API_URL",
    "GITHUB_GRAPHQL_URL",
    "WORKSPACE_ROOT",
    "SOURCE_REPO_PATH",
    "SOURCE_REPO_URL",
    "SOURCE_CACHE_ROOT",
    "SYMPHONY_REPO_PATH",
    "GITHUB_ISSUE_IDENTIFIER",
    "ISSUE_IDENTIFIER",
    "SYMPHONY_LOG_FORMAT",
    "LOG_FORMAT",
    "SYMPHONY_LOG_LEVEL",
    "LOG_LEVEL",
    "SYMPHONY_LOG_METADATA",
    "SYMPHONY_LOG_REDACT_KEYS",
    "SYMPHONY_LOG_MAX_METADATA_VALUE_LENGTH",
    "SYMPHONY_WORKFLOW_PATH",
    "WORKFLOW_PATH"
  ]

  defp expected_cache_dir_for(url) do
    url
    |> String.trim()
    |> String.trim_trailing("/")
    |> String.replace_suffix(".git", "")
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  defp with_env(pairs, fun) do
    keys = Enum.uniq(@tracked_env_vars ++ Enum.map(pairs, &elem(&1, 0)))
    original = Enum.map(keys, fn key -> {key, System.get_env(key)} end)

    try do
      Enum.each(keys, &System.delete_env/1)

      Enum.each(pairs, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      fun.()
    after
      Enum.each(original, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end
  end
end
