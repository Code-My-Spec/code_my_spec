defmodule CodeMySpec.Migration.ComponentsTravelTest do
  @moduledoc """
  Components as records, step 6 (3aeb66cf): a migration carries a project's
  components and their dependencies, and a frozen project arrives frozen. They
  used to be derived — the destination rebuilt them from files — but an
  architecture authored through the tools exists nowhere else.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Migration
  alias CodeMySpec.Projects.Project

  defp paid(scope) do
    account = scope.active_account |> Ecto.Changeset.change(%{plan: :paid}) |> Repo.update!()
    %{scope | active_account: account}
  end

  defp by_name(scope), do: Map.new(Components.list_components(scope), &{&1.module_name, &1})

  defp edges(scope),
    do:
      scope
      |> Components.list_dependencies()
      |> Enum.map(
        &{&1.source_component.module_name, &1.target_component.module_name, &1.provenance}
      )
      |> Enum.sort()

  setup do
    source = full_scope_fixture()

    accounts =
      component_fixture(source, %{
        name: "Accounts",
        module_name: "MyApp.Accounts",
        type: "context",
        description: "Who uses it",
        provenance: :authored
      })

    user =
      component_fixture(source, %{
        name: "User",
        module_name: "MyApp.Accounts.User",
        type: "schema",
        provenance: :discovered
      })

    {:ok, _} = Components.update_component(source, user, %{parent_component_id: accounts.id})

    web =
      component_fixture(source, %{name: "Web", module_name: "MyApp.Web", provenance: :authored})

    {:ok, _} =
      Components.create_dependency(source, %{
        source_component_id: web.id,
        target_component_id: accounts.id,
        provenance: :authored
      })

    frozen_at = ~U[2026-10-02 01:55:12.000000Z]

    Repo.update_all(from(p in Project, where: p.id == ^source.active_project_id),
      set: [components_authored_at: frozen_at]
    )

    %{
      payload: Migration.export_project(source),
      destination: paid(full_scope_fixture()),
      frozen_at: frozen_at
    }
  end

  test "components arrive with their type, description, provenance and parent", ctx do
    assert {:ok, _} = Migration.import_project(ctx.destination, ctx.payload)

    arrived = by_name(ctx.destination)
    assert arrived["MyApp.Accounts"].type == "context"
    assert arrived["MyApp.Accounts"].description == "Who uses it"
    assert arrived["MyApp.Accounts"].provenance == :authored
    assert arrived["MyApp.Accounts.User"].provenance == :discovered
    assert arrived["MyApp.Accounts.User"].parent_component_id == arrived["MyApp.Accounts"].id
  end

  test "dependencies arrive, by module name", ctx do
    assert {:ok, _} = Migration.import_project(ctx.destination, ctx.payload)
    assert edges(ctx.destination) == [{"MyApp.Web", "MyApp.Accounts", :authored}]
  end

  test "a frozen project arrives frozen", ctx do
    assert {:ok, _} = Migration.import_project(ctx.destination, ctx.payload)

    assert Repo.get!(Project, ctx.destination.active_project_id).components_authored_at ==
             ctx.frozen_at
  end

  test "it survives the wire, and a second run adds nothing", ctx do
    over_the_wire = ctx.payload |> Jason.encode!() |> Jason.decode!()

    assert {:ok, _} = Migration.import_project(ctx.destination, over_the_wire)
    assert {:ok, _} = Migration.import_project(ctx.destination, over_the_wire)

    assert map_size(by_name(ctx.destination)) == 3
    assert length(edges(ctx.destination)) == 1
  end

  test "components are no longer listed as derived" do
    refute "components" in Migration.derived_kinds()
  end
end
