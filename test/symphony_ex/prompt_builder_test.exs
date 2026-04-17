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

  defp tmp_path(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-prompt-builder-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
