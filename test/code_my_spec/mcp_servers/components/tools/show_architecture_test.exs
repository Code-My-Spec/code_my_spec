defmodule CodeMySpec.McpServers.Components.Tools.ShowArchitectureTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.McpServers.Components.Tools.ShowArchitecture
  alias Anubis.Server.Frame

  describe "ShowArchitecture tool" do
    setup do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      %{scope: scope}
    end

    test "returns empty architecture when no components with stories exist", %{scope: scope} do
      _component_without_story = component_fixture(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      assert response.type == :tool

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)
      assert parsed["architecture"]["components"] == []
    end

    test "returns components with stories and their dependencies", %{scope: scope} do
      root = component_fixture(scope, %{name: "Root"})
      dep1 = component_fixture(scope, %{name: "Dep1"})
      dep2 = component_fixture(scope, %{name: "Dep2"})

      story_fixture(scope, %{component_id: root.id})
      dependency_fixture(scope, root, dep1)
      dependency_fixture(scope, dep1, dep2)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      assert response.type == :tool

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)
      architecture = parsed["architecture"]["components"]

      assert length(architecture) == 1

      root_entry = Enum.find(architecture, &(&1["component"]["id"] == root.id))

      assert root_entry["depth"] == 0
      assert root_entry["component"]["name"] == "Root"
      assert root_entry["component"]["stories_count"] >= 1
    end

    test "shows shared dependencies multiple times", %{scope: scope} do
      root1 = component_fixture(scope, %{name: "Root1"})
      root2 = component_fixture(scope, %{name: "Root2"})
      shared_dep = component_fixture(scope, %{name: "SharedDep"})

      story_fixture(scope, %{component_id: root1.id})
      story_fixture(scope, %{component_id: root2.id})
      dependency_fixture(scope, root1, shared_dep)
      dependency_fixture(scope, root2, shared_dep)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)

      content_text = hd(response.content)["text"]
      parsed = Jason.decode!(content_text)
      architecture = parsed["architecture"]["components"]

      assert length(architecture) == 2

      Enum.filter(architecture, &(&1["depth"] == 0))
    end

    test "handles scope validation errors" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = ShowArchitecture.execute(%{}, frame)
      assert response.type == :tool
      assert response.isError == true
    end
  end
end
