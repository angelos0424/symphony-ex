defmodule SymphonyEx.PromptBuilderTest do
  use ExUnit.Case, async: false

  alias SymphonyEx.Domain.Issue
  alias SymphonyEx.PromptBuilder

  setup do
    previous = System.get_env("GSTACK_ROOT")

    on_exit(fn ->
      if previous do
        System.put_env("GSTACK_ROOT", previous)
      else
        System.delete_env("GSTACK_ROOT")
      end
    end)

    :ok
  end

  test "injects guidance for referenced gstack skills" do
    root = tmp_path("gstack-root")
    skill_path = Path.join([root, "gstack-design-review", "SKILL.md"])
    File.mkdir_p!(Path.dirname(skill_path))
    File.write!(skill_path, "# skill\n")
    System.put_env("GSTACK_ROOT", root)

    workflow_path = tmp_path("workflow.md")
    File.write!(workflow_path, "Task: <%= issue.title %>\n")

    issue = %Issue{
      id: "1",
      identifier: "10",
      title: "Design audit",
      description: "$gstack-design-review 실행",
      state: "Todo"
    }

    assert {:ok, prompt} =
             PromptBuilder.build(workflow_path, issue,
               workspace_path: Path.dirname(workflow_path)
             )

    assert prompt =~ "## Required external references"
    assert prompt =~ "$gstack-design-review"
    assert prompt =~ skill_path
    assert prompt =~ "Begin embedded SKILL.md for $gstack-design-review"
    assert prompt =~ "# skill"
    assert prompt =~ "Task: Design audit"
  end

  test "fails when referenced gstack skill is missing" do
    root = tmp_path("empty-gstack-root")
    File.mkdir_p!(root)
    System.put_env("GSTACK_ROOT", root)

    workflow_path = tmp_path("workflow-missing.md")
    File.write!(workflow_path, "Task: <%= issue.title %>\n")

    issue = %Issue{
      id: "1",
      identifier: "10",
      title: "Design audit",
      description: "$gstack-not-installed 실행",
      state: "Todo"
    }

    assert {:error, {:missing_skill_reference, "gstack-not-installed", paths}} =
             PromptBuilder.build(workflow_path, issue,
               workspace_path: Path.dirname(workflow_path)
             )

    assert Enum.any?(paths, &String.ends_with?(&1, "gstack-not-installed/SKILL.md"))
  end

  test "strips embedded symphony status blocks from the rendered prompt while preserving user instructions" do
    workflow_path = tmp_path("workflow-status.md")
    File.write!(workflow_path, "Task: <%= issue.title %>\nBody:\n<%= issue.description %>\n")

    issue = %Issue{
      id: "1",
      identifier: "11",
      title: "Review cp progress",
      description:
        Enum.join(
          [
            "Service: orchestration",
            "Paths: lib/symphony_ex/orchestrator.ex",
            "",
            "Review the current cp rollout.",
            "",
            "<!-- symphony:status -->",
            "## Symphony Status",
            "- Final status: in_review",
            "- Attempt: 0",
            "<!-- /symphony:status -->"
          ],
          "\n"
        ),
      state: "Todo"
    }

    assert {:ok, prompt} = PromptBuilder.build(workflow_path, issue)
    assert prompt =~ "Review the current cp rollout."
    refute prompt =~ "## Symphony Status"
    refute prompt =~ "Final status: in_review"
  end

  test "default workflow gates PR review feedback behind explicit review tasks" do
    workflow_path = Path.expand("../../WORKFLOW.md", __DIR__)

    issue = %Issue{
      id: "1",
      identifier: "45",
      title: "Create README setup PR",
      description: "@Task\n설치, 실행 등 기본적인 안내항목을 README.md로 생성하고 pr 만들어줘.",
      state: "In Progress"
    }

    assert {:ok, prompt} = PromptBuilder.build(workflow_path, issue)
    assert prompt =~ "## PR Review Feedback Policy"
    assert prompt =~ "visibility is not permission"
    assert prompt =~ "Do not edit files, commit, or push for those comments."
    assert prompt =~ "Only apply PR review feedback for explicit commands"
    assert prompt =~ "@Task review comment"
    assert prompt =~ "## PR Creation Stop Condition"
    assert prompt =~ "After those conditions are met, do not make additional commits"

    assert prompt =~
             "Review feedback is actionable only when it appears inside the generated follow-up task"
  end

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-prompt-builder-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
