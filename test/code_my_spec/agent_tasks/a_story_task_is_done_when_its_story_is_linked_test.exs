defmodule CodeMySpec.AgentTasks.AStoryTaskIsDoneWhenItsStoryIsLinkedTest do
  @moduledoc """
  A revision-mode architecture task for one story's `component_linked` is
  done when that story has a component. Other unlinked stories are their own
  tasks, and an orphan context is not a gate (John, 2026-10-02).
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Stories

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("test")

    scope =
      put_fixture_environment(
        %{working_copy_scope_fixture() | cwd: tmp},
        Environment.new(:local, tmp)
      )

    :ok = register_working_copy_environment(scope, fixture_environment(scope))

    # An orphan context exists, so `command/2` records revision mode.
    component = component_fixture(scope, %{type: "context"})
    {:ok, _prompt} = ArchitectureDesign.command(scope, %{id: 1})

    %{scope: scope, component: component, mine: story_fixture(scope), other: story_fixture(scope)}
  end

  test "its story unlinked: not done, and it says which", %{scope: scope, mine: mine} do
    assert {:ok, :invalid, feedback} = ArchitectureDesign.evaluate(scope, %{story_id: mine.id})
    assert feedback =~ "Story #{mine.number}"
  end

  test "its story linked: done, whatever else is unlinked or orphaned", ctx do
    {:ok, _} = Stories.set_story_component(ctx.scope, ctx.mine, ctx.component.id)

    assert {:ok, :valid} = ArchitectureDesign.evaluate(ctx.scope, %{story_id: ctx.mine.id})
  end
end
