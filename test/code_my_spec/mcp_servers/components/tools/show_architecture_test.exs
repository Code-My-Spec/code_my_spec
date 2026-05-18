defmodule CodeMySpec.McpServers.Components.Tools.ShowArchitectureTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  alias CodeMySpec.McpServers.Components.Tools.ShowArchitecture
  alias Anubis.Server.Frame

  # `ShowArchitecture` returns a Mermaid `flowchart TD` (see
  # `Architecture.MermaidProjector`). The projector filters components
  # to surface-style types (`context`, `liveview`, `live_context`,
  # `controller`, `channel`) and rolls up dependencies declared on
  # child components to the nearest surface ancestor. Story linkage is
  # NOT a filter — every surface-typed component appears.

  describe "ShowArchitecture tool" do
    setup do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      %{scope: scope}
    end

    test "returns a bare flowchart when the project has no surface-typed components",
         %{scope: scope} do
      # A schema component is not in the graph_types whitelist, so it
      # does not show up in the architecture flowchart.
      schema_component_fixture(scope, %{module_name: "MyApp.OnlyASchema"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      assert response.type == :tool

      mermaid = hd(response.content)["text"]
      assert mermaid == "flowchart TD",
             "expected a bare `flowchart TD` for a project with no surface components, got:\n#{mermaid}"
    end

    test "surface components render as nodes and dependencies as edges",
         %{scope: scope} do
      root =
        component_fixture(scope, %{
          name: "Root",
          module_name: "MyApp.Root",
          type: "context"
        })

      dep1 =
        component_fixture(scope, %{
          name: "Dep1",
          module_name: "MyApp.Dep1",
          type: "context"
        })

      dep2 =
        component_fixture(scope, %{
          name: "Dep2",
          module_name: "MyApp.Dep2",
          type: "context"
        })

      dependency_fixture(scope, root, dep1)
      dependency_fixture(scope, dep1, dep2)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      mermaid = hd(response.content)["text"]

      assert String.starts_with?(mermaid, "flowchart TD\n"),
             "expected `flowchart TD` prefix, got:\n#{mermaid}"

      # Nodes: `myapp_root[MyApp.Root]` (sanitized id + module label)
      assert mermaid =~ "myapp_root[MyApp.Root]"
      assert mermaid =~ "myapp_dep1[MyApp.Dep1]"
      assert mermaid =~ "myapp_dep2[MyApp.Dep2]"

      # Direct edges from declared dependencies
      assert mermaid =~ "myapp_root --> myapp_dep1"
      assert mermaid =~ "myapp_dep1 --> myapp_dep2"
    end

    test "a shared dependency is reached by every dependent surface",
         %{scope: scope} do
      root1 =
        component_fixture(scope, %{
          name: "Root1",
          module_name: "MyApp.Root1",
          type: "context"
        })

      root2 =
        component_fixture(scope, %{
          name: "Root2",
          module_name: "MyApp.Root2",
          type: "context"
        })

      shared_dep =
        component_fixture(scope, %{
          name: "SharedDep",
          module_name: "MyApp.SharedDep",
          type: "context"
        })

      dependency_fixture(scope, root1, shared_dep)
      dependency_fixture(scope, root2, shared_dep)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      mermaid = hd(response.content)["text"]

      # Both roots reach the shared dep — two distinct edges land on it.
      assert mermaid =~ "myapp_root1 --> myapp_shareddep"
      assert mermaid =~ "myapp_root2 --> myapp_shareddep"
    end

    test "handles scope validation errors" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == true
    end
  end
end
