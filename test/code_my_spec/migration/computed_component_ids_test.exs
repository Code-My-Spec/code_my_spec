defmodule CodeMySpec.Migration.ComputedComponentIdsTest do
  @moduledoc """
  A migrated story names its component by computing the id, not by looking it up.

  Components are `@derived` — `CodeMySpec.Migration` deliberately does not carry
  them, because the destination rebuilds them from the working copy on first
  sync. That sync happens *after* the import, so resolving the id against the
  components table asked a question at the one moment it could not be answered:
  every story on a first migration landed unlinked. Broken Oaths arrived with 52
  stories, 38 linked in the source and 0 in the destination, against 171
  components that showed up minutes later and matched by name exactly.

  A component's id is a pure function of its project and its module name, so the
  destination can name the component without the row existing yet. That is the
  whole fix, and it needs nothing stored: the module name is input the payload
  already carries, not state worth keeping — a story someone re-points later
  would otherwise carry a module name that no longer describes it.

  The id cannot simply travel for the same reason it can be computed: the
  project id is part of it, and a migration changes the project. The same module
  is a different id on the far side.

  What makes the early link safe is that `component_linked` asks whether the
  component exists rather than whether the field is set — so a story pointing at
  a component that has not synced reads unsatisfied, and flips on its own when
  it does.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components.Component

  @module "BrokenOaths.Feudal.Rebellion.War"

  test "the id a component gets is the id its project and module determine" do
    scope = full_scope_fixture()

    component = component_fixture(scope, %{module_name: @module})

    assert component.id == Component.deterministic_id(scope.active_project_id, @module),
           "if these ever diverge, an import computing the id would point every " <>
             "migrated story at a row nothing creates"
  end

  # Why an id cannot be carried across a migration, stated as a property rather
  # than as a comment. The project is part of the name being hashed.
  test "the same module in two projects is two different components" do
    one = full_scope_fixture()
    two = full_scope_fixture()

    refute Component.deterministic_id(one.active_project_id, @module) ==
             Component.deterministic_id(two.active_project_id, @module)
  end

  test "and the same module in one project is always the same component" do
    scope = full_scope_fixture()

    assert Component.deterministic_id(scope.active_project_id, @module) ==
             Component.deterministic_id(scope.active_project_id, @module)
  end

  # The destination can name a component before the working copy has produced
  # it, which is the property the import depends on.
  test "an id can be computed for a component that does not exist" do
    scope = full_scope_fixture()

    id = Component.deterministic_id(scope.active_project_id, "BrokenOaths.NotSyncedYet")

    assert is_binary(id)
    assert CodeMySpec.Repo.get(Component, id) == nil
  end
end
