defmodule CodeMySpec.Components.Tools.AuthoringTheComponentGraphTest do
  @moduledoc """
  Components as records, step 1 (3aeb66cf): the tools an architect uses to
  author the component graph directly — its edges, every type, and parents —
  without a spec file in between.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Types

  setup do
    scope = full_scope_fixture()

    %{
      scope: scope,
      frame: %Frame{assigns: %{current_scope: scope}},
      web: component_fixture(scope, %{name: "Web", module_name: "MyApp.Web"}),
      accounts: component_fixture(scope, %{name: "Accounts", module_name: "MyApp.Accounts"})
    }
  end

  defp edges(scope),
    do:
      scope
      |> Components.list_dependencies()
      |> Enum.map(&{&1.source_component_id, &1.target_component_id})

  describe "dependencies" do
    test "are added and removed by id", ctx do
      args = %{source_component_id: ctx.web.id, target_component_id: ctx.accounts.id}

      added =
        ToolLibrary.run(
          "add_dependency",
          args,
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, added)
      assert response_text(added) =~ "`MyApp.Web` now depends on `MyApp.Accounts`"
      assert edges(ctx.scope) == [{ctx.web.id, ctx.accounts.id}]

      removed =
        ToolLibrary.run(
          "remove_dependency",
          args,
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, removed)
      assert edges(ctx.scope) == []
    end

    test "cannot reach a component in another project", ctx do
      elsewhere = full_scope_fixture()
      theirs = component_fixture(elsewhere, %{name: "Theirs", module_name: "Other.Theirs"})

      reply =
        ToolLibrary.run(
          "add_dependency",
          %{source_component_id: ctx.web.id, target_component_id: theirs.id},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:error, _}, reply)
      assert edges(ctx.scope) == []
    end

    test "a component cannot depend on itself", ctx do
      reply =
        ToolLibrary.run(
          "add_dependency",
          %{source_component_id: ctx.web.id, target_component_id: ctx.web.id},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:error, _}, reply)
    end

    test "removing one that does not exist says so", ctx do
      reply =
        ToolLibrary.run(
          "remove_dependency",
          %{source_component_id: ctx.web.id, target_component_id: ctx.accounts.id},
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:error, _}, reply)
      assert response_text(reply) =~ "No such dependency"
    end
  end

  describe "types and parents" do
    test "create and update offer every authorable type", _ctx do
      for name <- ~w(create_component update_component) do
        {:ok, tool} = ToolLibrary.fetch(name)

        assert get_in(CodeMySpec.Tools.input_schema(tool), ["properties", "type", "enum"]) ==
                 Types.all()
      end
    end

    test "update sets any type and a parent", ctx do
      reply =
        ToolLibrary.run(
          "update_component",
          %{
            component_id: ctx.web.id,
            type: "infrastructure",
            parent_component_id: ctx.accounts.id
          },
          Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, reply)
      updated = Components.get_component(ctx.scope, ctx.web.id)
      assert updated.type == "infrastructure"
      assert updated.parent_component_id == ctx.accounts.id
    end
  end

  # What a sync reads to leave them alone (a_sync_leaves_authored_records_alone_test).
  test "what the tools write is marked as authored", ctx do
    ToolLibrary.run(
      "add_dependency",
      %{source_component_id: ctx.web.id, target_component_id: ctx.accounts.id},
      Map.put(ctx.frame.assigns, :scope, ctx.frame.assigns[:current_scope])
    )

    {:ok, _created} =
      ToolLibrary.run(
        "create_component",
        %{name: "Billing", module_name: "MyApp.Billing", type: "context"},
        %{scope: put_fixture_environment(ctx.scope, nil)}
      )

    assert [%{provenance: :authored}] = Components.list_dependencies(ctx.scope)

    assert %{provenance: :authored} =
             ctx.scope
             |> Components.list_components()
             |> Enum.find(&(&1.module_name == "MyApp.Billing"))
  end

  test "the roles that author architecture carry the dependency tools" do
    for role <- [:product, :coding, :main], tool <- ~w(add_dependency remove_dependency) do
      assert RoleProfile.carries?(role, tool), "#{role} cannot #{tool}"
    end
  end
end
