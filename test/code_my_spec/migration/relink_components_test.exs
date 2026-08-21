defmodule CodeMySpec.Migration.RelinkComponentsTest do
  @moduledoc """
  The last step of a migration, and the only one that cannot run during it.

  Components are `@derived` — `CodeMySpec.Migration` deliberately does not carry
  them, because the destination rebuilds them from the working copy — so
  `import_project/2` resolves each story's `component_module_name` against the
  components that exist at import time, which on a first migration is none of
  them. The working copy has not synced yet.

  Measured 2026-08-21 on Broken Oaths: 52 stories arrived, 38 of them linked in
  the source and 0 in the destination, against 171 components that showed up
  minutes later and matched by name exactly — all 13 distinct module names, none
  missing. `analyze_story_linkage` reported every story unlinked and
  `get_next_requirement` offered `architecture_designed`, as though the project
  had never been mapped. The export's own comment predicted the shape: "a
  migrated project reports 0/0 satisfied for everything, which reads as 'nothing
  is done' rather than 'nothing is linked'".

  Nothing was dropping the join. It was computed once, at the only moment it
  could not be known, and thrown away. `stories.component_module_name` keeps the
  natural key the wire format already used; this is where it is spent.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Migration
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story

  @module "BrokenOaths.Feudal.Rebellion.War"

  setup do
    %{scope: full_scope_fixture()}
  end

  defp reload(story), do: Repo.get!(Story, story.id)

  test "a story waiting on a module is linked to it", ctx do
    component = component_fixture(ctx.scope, %{module_name: @module})
    story = story_fixture(ctx.scope, %{component_module_name: @module, component_id: nil})

    assert {:ok, 1} = Migration.relink_components(ctx.scope)
    assert reload(story).component_id == component.id
  end

  test "a story already pointed somewhere is left alone", ctx do
    theirs = component_fixture(ctx.scope, %{module_name: "BrokenOaths.Combat"})
    _named = component_fixture(ctx.scope, %{module_name: @module})

    story =
      story_fixture(ctx.scope, %{component_module_name: @module, component_id: theirs.id})

    assert {:ok, 0} = Migration.relink_components(ctx.scope)

    assert reload(story).component_id == theirs.id,
           "the destination is authoritative once anybody edits the link there — the " <>
             "same rule the migration applies to title, narrative and description"
  end

  test "a story naming a module that has not synced yet stays unlinked", ctx do
    _other = component_fixture(ctx.scope, %{module_name: "BrokenOaths.Combat"})

    story =
      story_fixture(ctx.scope, %{
        component_module_name: "BrokenOaths.NotBuiltYet",
        component_id: nil
      })

    assert {:ok, 0} = Migration.relink_components(ctx.scope)
    assert reload(story).component_id == nil
  end

  test "a story that never migrated is untouched", ctx do
    _component = component_fixture(ctx.scope, %{module_name: @module})
    story = story_fixture(ctx.scope, %{component_module_name: nil, component_id: nil})

    assert {:ok, 0} = Migration.relink_components(ctx.scope)

    assert reload(story).component_id == nil,
           "a null module name is not a wildcard; it means this story was never told " <>
             "which component it belongs to"
  end

  test "another project's stories are not touched", ctx do
    other_scope = full_scope_fixture()
    _component = component_fixture(ctx.scope, %{module_name: @module})

    theirs =
      story_fixture(other_scope, %{component_module_name: @module, component_id: nil})

    assert {:ok, 0} = Migration.relink_components(ctx.scope)
    assert reload(theirs).component_id == nil
  end

  # Safe to run again is the whole reason it can be a task somebody runs when
  # they notice, rather than something that has to happen at exactly one moment.
  test "running it twice links no more the second time", ctx do
    component = component_fixture(ctx.scope, %{module_name: @module})
    story = story_fixture(ctx.scope, %{component_module_name: @module, component_id: nil})

    assert {:ok, 1} = Migration.relink_components(ctx.scope)
    assert {:ok, 0} = Migration.relink_components(ctx.scope)

    assert reload(story).component_id == component.id
  end

  test "several stories on one module all link to it", ctx do
    component = component_fixture(ctx.scope, %{module_name: @module})

    stories =
      for _ <- 1..3,
          do: story_fixture(ctx.scope, %{component_module_name: @module, component_id: nil})

    assert {:ok, 3} = Migration.relink_components(ctx.scope)

    for story <- stories, do: assert(reload(story).component_id == component.id)
  end
end
