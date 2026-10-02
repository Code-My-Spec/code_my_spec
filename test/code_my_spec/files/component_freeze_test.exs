defmodule CodeMySpec.Files.ComponentFreezeTest do
  @moduledoc """
  The one-time freeze of a project's components into records (3aeb66cf, step 3).
  The stale-checkout cases are here rather than in a spex: an old worktree that
  still carries a deleted spec is a state no tool produces.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentFreeze
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies
  alias CodeMySpec.WorkingCopies.WorkingCopy

  defp spec!(scope, copy_id, module) do
    Repo.insert!(%CodeMySpec.Files.File{
      project_id: scope.active_project_id,
      working_copy_id: copy_id,
      path: ".code_my_spec/spec/#{Macro.underscore(module)}.spec.md",
      role: :spec,
      fingerprint: "sha-#{System.unique_integer([:positive])}",
      size: 100,
      valid: true,
      validation_errors: %{"data" => %{"module_name" => module}}
    })
  end

  defp stale_copy!(scope) do
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "old", device: device_fixture(scope))
    long_ago = DateTime.add(DateTime.utc_now(), -30 * 86_400)

    Repo.update_all(from(w in WorkingCopy, where: w.id == ^copy.id),
      set: [last_seen_at: long_ago]
    )

    copy
  end

  defp provenance(scope, module),
    do: Enum.find(Components.list_components(scope), &(&1.module_name == module)).provenance

  setup do
    scope = full_scope_fixture()
    # The scope's own checkout, seen just now: live.
    live = scope.active_working_copy_id

    web = component_fixture(scope, %{name: "Web", module_name: "MyApp.Web"})
    accounts = component_fixture(scope, %{name: "Accounts", module_name: "MyApp.Accounts"})
    component_fixture(scope, %{name: "Helper", module_name: "MyApp.Helper"})
    component_fixture(scope, %{name: "Legacy", module_name: "MyApp.Legacy"})

    component_fixture(scope, %{
      name: "Billing",
      module_name: "MyApp.Billing",
      provenance: :authored
    })

    spec!(scope, live, "MyApp.Web")
    spec!(scope, live, "MyApp.Accounts")
    spec!(scope, live, "MyApp.Ghost")
    spec!(scope, stale_copy!(scope).id, "MyApp.Legacy")

    {:ok, _} =
      Components.create_dependency(scope, %{
        source_component_id: web.id,
        target_component_id: accounts.id
      })

    %{scope: scope, project_id: scope.active_project_id}
  end

  test "a dry run reports what it would do and writes nothing", ctx do
    plan = ComponentFreeze.plan(ctx.project_id)

    assert plan.to_author == ["MyApp.Accounts", "MyApp.Web"]
    assert plan.to_discover == 2
    assert plan.already_authored == 1
    assert plan.edges_to_author == 1
    assert plan.stale_spec_only == ["MyApp.Legacy"]
    assert plan.specs_without_component == ["MyApp.Ghost"]

    assert provenance(ctx.scope, "MyApp.Web") == nil
    assert Repo.get!(Project, ctx.project_id).components_authored_at == nil
  end

  test "freezing marks spec-named components authored and the rest discovered", ctx do
    assert {:ok, _} = ComponentFreeze.freeze(ctx.project_id)

    assert provenance(ctx.scope, "MyApp.Web") == :authored
    assert provenance(ctx.scope, "MyApp.Accounts") == :authored
    assert provenance(ctx.scope, "MyApp.Helper") == :discovered
    # Named only by a stale checkout's spec.
    assert provenance(ctx.scope, "MyApp.Legacy") == :discovered
    assert provenance(ctx.scope, "MyApp.Billing") == :authored
    assert [%{provenance: :authored}] = Components.list_dependencies(ctx.scope)
  end

  test "a frozen project is stamped and a second freeze changes nothing", ctx do
    assert {:ok, _} = ComponentFreeze.freeze(ctx.project_id)
    assert %DateTime{} = Repo.get!(Project, ctx.project_id).components_authored_at

    component_fixture(ctx.scope, %{name: "Later", module_name: "MyApp.Later"})

    assert {:ok, :already_frozen} = ComponentFreeze.freeze(ctx.project_id)
    assert provenance(ctx.scope, "MyApp.Later") == nil
  end
end
