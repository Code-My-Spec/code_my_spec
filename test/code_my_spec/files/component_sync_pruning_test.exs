defmodule CodeMySpec.Files.ComponentSyncPruningTest do
  @moduledoc """
  A component that could not be read is unknown, not deleted.

  `ComponentSync` builds `merged` from the specs it can parse, and a full sync
  deletes every existing component absent from it. A spec that cannot be read is
  therefore indistinguishable from one that no longer exists — the module's own
  comment says so — and on the light harness that is not an edge case. The
  server holds no working copy, so any spec without scanner-stored data reads as
  `{:error, :no_environment}`.

  Observed before the fix: a manifest change triggered a full resync, 904 of 904
  components changed, `:no_environment` warnings throughout. Nothing was lost
  only because 1494 of 1519 specs carry parsed data from the scanner and never
  reach the disk path.

  The rule asserted here is the one the harness already applies to an empty
  scan, for the same reason: do not delete on the strength of a picture you
  could not build.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Repo

  # A spec File row with no scanner-stored data, so the sync must fall back to
  # reading it — which, with no environment, it cannot.
  defp unreadable_spec!(scope, path) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :spec,
      fingerprint: "sha-#{System.unique_integer([:positive])}",
      size: 100,
      valid: true
    })
  end

  setup do
    scope = full_scope_fixture()

    component =
      component_fixture(scope, %{name: "Widgets", module_name: "CodeMySpec.Widgets"})

    # No environment: exactly the light harness server's situation.
    %{scope: %{scope | environment: nil, cwd: nil}, component: component}
  end

  test "a full sync that could not read a spec does not delete its component", %{
    scope: scope,
    component: component
  } do
    unreadable_spec!(scope, ".code_my_spec/spec/code_my_spec/widgets.spec.md")

    ComponentSync.sync_from_files(scope)

    assert Components.get_component(scope, component.id),
           "the component was deleted because a file could not be opened — architecture " <>
             "state destroyed by an unreadable spec, which is the failure this guards"
  end

  test "an unreadable spec does not stop the sync succeeding" do
    # Refusing outright would take the whole sync down for one bad file. The
    # rule is "do not prune", not "do not sync".
    scope = full_scope_fixture()
    scope = %{scope | environment: nil, cwd: nil}

    unreadable_spec!(scope, ".code_my_spec/spec/code_my_spec/anything.spec.md")

    assert {:ok, _} = ComponentSync.sync_from_files(scope)
  end
end
