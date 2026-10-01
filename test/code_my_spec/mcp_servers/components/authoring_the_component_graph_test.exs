defmodule CodeMySpec.McpServers.Components.AuthoringTheComponentGraphTest do
  @moduledoc """
  Components as records, step 1 (3aeb66cf): the tools an architect uses to
  author the component graph directly — its edges, every type, and parents —
  without a spec file in between.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Components
  alias CodeMySpec.Components.Types
  alias CodeMySpec.McpServers.Components.Tools.AddDependency
  alias CodeMySpec.McpServers.Components.Tools.CreateComponent
  alias CodeMySpec.McpServers.Components.Tools.RemoveDependency
  alias CodeMySpec.McpServers.Components.Tools.UpdateComponent

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

      assert {:reply, added, _} = AddDependency.execute(args, ctx.frame)
      refute added.isError
      assert response_text(added) =~ "`MyApp.Web` now depends on `MyApp.Accounts`"
      assert edges(ctx.scope) == [{ctx.web.id, ctx.accounts.id}]

      assert {:reply, removed, _} = RemoveDependency.execute(args, ctx.frame)
      refute removed.isError
      assert edges(ctx.scope) == []
    end

    test "cannot reach a component in another project", ctx do
      elsewhere = full_scope_fixture()
      theirs = component_fixture(elsewhere, %{name: "Theirs", module_name: "Other.Theirs"})

      assert {:reply, reply, _} =
               AddDependency.execute(
                 %{source_component_id: ctx.web.id, target_component_id: theirs.id},
                 ctx.frame
               )

      assert reply.isError
      assert edges(ctx.scope) == []
    end

    test "a component cannot depend on itself", ctx do
      assert {:reply, reply, _} =
               AddDependency.execute(
                 %{source_component_id: ctx.web.id, target_component_id: ctx.web.id},
                 ctx.frame
               )

      assert reply.isError
    end

    test "removing one that does not exist says so", ctx do
      assert {:reply, reply, _} =
               RemoveDependency.execute(
                 %{source_component_id: ctx.web.id, target_component_id: ctx.accounts.id},
                 ctx.frame
               )

      assert reply.isError
      assert response_text(reply) =~ "No such dependency"
    end
  end

  describe "types and parents" do
    test "create and update offer every authorable type", _ctx do
      for tool <- [CreateComponent, UpdateComponent] do
        assert get_in(tool.input_schema(), ["properties", "type", "enum"]) == Types.all()
      end
    end

    test "update sets any type and a parent", ctx do
      assert {:reply, reply, _} =
               UpdateComponent.execute(
                 %{id: ctx.web.id, type: "infrastructure", parent_component_id: ctx.accounts.id},
                 ctx.frame
               )

      refute reply.isError
      updated = Components.get_component(ctx.scope, ctx.web.id)
      assert updated.type == "infrastructure"
      assert updated.parent_component_id == ctx.accounts.id
    end
  end

  test "the roles that author architecture carry the dependency tools" do
    for role <- [:product, :coding, :main], tool <- ~w(add_dependency remove_dependency) do
      assert RoleProfile.carries?(role, tool), "#{role} cannot #{tool}"
    end
  end
end
