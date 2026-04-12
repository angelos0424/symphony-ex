defmodule SymphonyEx.PromptBuilder do
  @moduledoc """
  Builds the agent prompt from WORKFLOW.md template and issue data.
  Uses EEx for template rendering.
  """

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.WorkflowStore

  @spec build(String.t(), Issue.t(), keyword()) :: String.t()
  def build(workflow_path, issue, opts \\ []) do
    template = load_template(workflow_path, Keyword.get(opts, :workflow_store, WorkflowStore))
    build_from_template(template, issue, opts)
  end

  @spec build_from_template(String.t(), Issue.t(), keyword()) :: String.t()
  def build_from_template(template, issue, opts \\ []) do
    comments = Keyword.get(opts, :comments, [])
    context_docs = Keyword.get(opts, :context_docs, "")

    bindings = [
      issue: issue,
      comments: comments,
      context_docs: context_docs
    ]

    EEx.eval_string(template, bindings)
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
end
