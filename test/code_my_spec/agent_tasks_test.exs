defmodule CodeMySpec.AgentTasksTest do
  @moduledoc """
  Issue 3b943635: an agent starting `bdd_specs_exist` on an unlinked story saw
  only `Error generating prompt: :component_not_linked` and had to guess the
  remedy — while the error tuple it came from was already carrying a paragraph
  naming the two tools that fix it.

  These pin that the message survives rendering.
  """
  use ExUnit.Case, async: true

  doctest CodeMySpec.AgentTasks

  alias CodeMySpec.AgentTasks

  describe "format_error/1" do
    test "keeps the actionable message, on its own lines" do
      rendered =
        AgentTasks.format_error(
          {:component_not_linked,
           "Story 727 has no surface component linked.\n\nCall `create_component` first."}
        )

      assert rendered =~ "component_not_linked"
      assert rendered =~ "create_component"

      # The tag must not run into the message — an agent reads the first line
      # as the error and the rest as what to do about it.
      assert ["component_not_linked", "" | _] = String.split(rendered, "\n")
    end

    test "does not escape the message the way inspect/1 would" do
      rendered = AgentTasks.format_error({:oops, ~s(use `set_story_component` with "MyApp.Foo")})

      refute rendered =~ ~S(\")
      assert rendered =~ ~s(with "MyApp.Foo")
    end

    test "falls back to inspect for reasons carrying no message" do
      assert AgentTasks.format_error(:component_not_linked) == ":component_not_linked"
      assert AgentTasks.format_error({:badarg, 42}) == "{:badarg, 42}"
    end
  end

  describe "the errors real task modules return" do
    # WriteBddSpecs is the module the issue was filed against. Its unlinked
    # branch is the one whose guidance went missing, so assert the shape it
    # produces is the shape format_error/1 preserves.
    test "an unlinked story renders both the tag and the remedy" do
      {:error, reason} =
        CodeMySpec.AgentTasks.WriteBddSpecs.command(
          %CodeMySpec.Users.Scope{},
          %{story_id: nil}
        )

      rendered = AgentTasks.format_error(reason)

      assert rendered =~ "story_not_specified"
      assert rendered =~ "start_task"
    end
  end
end
