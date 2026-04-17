defmodule SymphonyEx.PromptBuilder do
  @moduledoc """
  Builds the agent prompt from WORKFLOW.md template and issue data.
  Uses EEx for template rendering.
  """

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.WorkflowStore

  @gstack_skill_token ~r/(^|[^\w-])\$(gstack-[a-z0-9-]+)\b/

  @spec build(String.t(), Issue.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def build(workflow_path, issue, opts \\ []) do
    template = load_template(workflow_path, Keyword.get(opts, :workflow_store, WorkflowStore))

    with {:ok, external_references} <- resolve_external_references(issue, opts) do
      {:ok,
       build_from_template(
         template,
         issue,
         Keyword.put(opts, :external_references, external_references)
       )}
    end
  end

  @spec build_from_template(String.t(), Issue.t(), keyword()) :: String.t()
  def build_from_template(template, issue, opts \\ []) do
    comments = Keyword.get(opts, :comments, [])
    context_docs = Keyword.get(opts, :context_docs, "")
    external_references = Keyword.get(opts, :external_references, [])

    bindings = [
      issue: issue,
      comments: comments,
      context_docs: context_docs
    ]

    template
    |> EEx.eval_string(bindings)
    |> prepend_external_reference_guidance(external_references)
  end

  @spec load_template(String.t(), module() | GenServer.name() | nil) :: String.t()
  def load_template(path, workflow_store \\ WorkflowStore) do
    case maybe_load_from_store(path, workflow_store) do
      nil -> load_template_from_disk(path)
      template -> template
    end
  end

  @spec maybe_load_from_store(String.t(), module() | GenServer.name() | nil) :: String.t() | nil
  defp maybe_load_from_store(_path, nil), do: nil

  defp maybe_load_from_store(path, workflow_store) do
    if Process.whereis(workflow_store) do
      snapshot = WorkflowStore.snapshot(workflow_store)

      if Path.expand(snapshot.workflow_path) == Path.expand(path) do
        snapshot.template
      end
    end
  end

  @spec load_template_from_disk(String.t()) :: String.t()
  defp load_template_from_disk(path) do
    content = File.read!(path)

    # Strip YAML front matter
    case Regex.run(~r/\A---\n.*?\n---\n(.*)/s, content) do
      [_, body] -> body
      nil -> content
    end
  end

  @spec resolve_external_references(Issue.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  defp resolve_external_references(%Issue{} = issue, opts) do
    issue.description
    |> extract_external_reference_tokens()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case resolve_external_reference(name, opts) do
        {:ok, reference} -> {:cont, {:ok, [reference | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, references} -> {:ok, Enum.reverse(references)}
      {:error, _reason} = error -> error
    end
  end

  @spec extract_external_reference_tokens(String.t() | nil) :: [String.t()]
  defp extract_external_reference_tokens(nil), do: []

  defp extract_external_reference_tokens(description) do
    @gstack_skill_token
    |> Regex.scan(description)
    |> Enum.map(fn [_full, _prefix, name] -> name end)
    |> Enum.uniq()
  end

  @spec resolve_external_reference(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  defp resolve_external_reference("gstack-" <> _rest = name, opts) do
    case resolve_gstack_skill_path(name, opts) do
      {:ok, path} ->
        {:ok, %{type: :skill, name: name, path: path, content: File.read!(path)}}

      :error ->
        {:error, {:missing_skill_reference, name, expected_gstack_skill_paths(name, opts)}}
    end
  end

  defp resolve_external_reference(name, _opts) do
    case System.find_executable(name) do
      nil -> {:error, {:missing_external_reference, name}}
      path -> {:ok, %{type: :command, name: name, path: path}}
    end
  end

  @spec resolve_gstack_skill_path(String.t(), keyword()) :: {:ok, String.t()} | :error
  defp resolve_gstack_skill_path(name, opts) do
    name
    |> expected_gstack_skill_paths(opts)
    |> Enum.find(&File.regular?/1)
    |> case do
      nil -> :error
      path -> {:ok, path}
    end
  end

  @spec expected_gstack_skill_paths(String.t(), keyword()) :: [String.t()]
  defp expected_gstack_skill_paths(name, opts) do
    opts
    |> gstack_skill_roots()
    |> Enum.map(&Path.join([&1, name, "SKILL.md"]))
    |> Enum.uniq()
  end

  @spec gstack_skill_roots(keyword()) :: [String.t()]
  defp gstack_skill_roots(opts) do
    workspace_path = Keyword.get(opts, :workspace_path)
    explicit_root = System.get_env("GSTACK_ROOT")
    home = System.user_home()

    [
      explicit_root,
      workspace_path && Path.join([find_repo_root(workspace_path), ".agents", "skills"]),
      Path.join([home, ".gstack", "repos", "gstack", ".agents", "skills"]),
      Path.join([home, ".codex", "skills", "gstack"])
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  @spec find_repo_root(String.t() | nil) :: String.t()
  defp find_repo_root(nil), do: File.cwd!()

  defp find_repo_root(workspace_path) do
    workspace_path = Path.expand(workspace_path)

    workspace_path
    |> Path.split()
    |> Enum.reduce_while([], fn segment, acc ->
      current = Path.join(acc ++ [segment])

      if File.dir?(Path.join(current, ".git")) do
        {:halt, current}
      else
        {:cont, acc ++ [segment]}
      end
    end)
    |> case do
      [] -> workspace_path
      path when is_binary(path) -> path
      parts when is_list(parts) -> Path.join(parts)
    end
  end

  @spec prepend_external_reference_guidance(String.t(), [map()]) :: String.t()
  defp prepend_external_reference_guidance(prompt, []), do: prompt

  defp prepend_external_reference_guidance(prompt, references) do
    render_external_reference_guidance(references) <> "\n\n" <> prompt
  end

  @spec render_external_reference_guidance([map()]) :: String.t()
  defp render_external_reference_guidance(references) do
    rendered_references =
      references
      |> Enum.map_join("\n", fn
        %{type: :skill, name: name, path: path, content: content} ->
          Enum.join(
            [
              "- `$#{name}` is an installed local skill reference. Its instructions are embedded below so you do not need to shell out to load it.",
              "  Source: #{path}",
              "  Begin embedded SKILL.md for $#{name}:",
              indent_block(content, "    "),
              "  End embedded SKILL.md for $#{name}."
            ],
            "\n"
          )

        %{type: :command, name: name, path: path} ->
          "- `$#{name}` is a literal shell command reference. Executable found at: #{path}"
      end)

    Enum.join(
      [
        "## Required external references",
        "The issue body contains explicit `$...` references. Do not approximate or substitute them.",
        "For embedded skills, follow the embedded instructions directly instead of trying to rediscover them from disk.",
        "If a referenced skill or command is unavailable, stop and report a blocker instead of inventing an alternative workflow.",
        rendered_references
      ],
      "\n"
    )
  end

  @spec indent_block(String.t(), String.t()) :: String.t()
  defp indent_block(text, prefix) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &(prefix <> &1))
  end
end
