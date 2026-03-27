defmodule CodeMySpec.McpServers.Stories.Tools.AnalyzeStoryLinkageTest do
  use ExUnit.Case, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Stories.Tools.AnalyzeStoryLinkage

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "reports all linked when stories are properly linked" do
      scope = full_scope_fixture()
      component = component_fixture(scope, %{module_name: "MyApp.Blog"})
      _story = story_fixture(scope, %{component_id: component.id, title: "Blog feature"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStoryLinkage.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Linked Stories"
      assert content =~ "MyApp.Blog"
      assert content =~ "Blog feature"
    end

    test "reports unlinked stories" do
      scope = full_scope_fixture()
      _story = story_fixture(scope, %{title: "Unlinked story"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStoryLinkage.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Unlinked Stories"
      assert content =~ "Unlinked story"
    end

    test "reports orphan components with no stories" do
      scope = full_scope_fixture()
      _component = component_fixture(scope, %{module_name: "MyApp.Orphan"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStoryLinkage.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Orphan Components"
      assert content =~ "MyApp.Orphan"
    end

    test "reports mixed state correctly" do
      scope = full_scope_fixture()
      linked_comp = component_fixture(scope, %{module_name: "MyApp.Linked"})
      _orphan_comp = component_fixture(scope, %{module_name: "MyApp.Orphan"})
      _linked_story = story_fixture(scope, %{component_id: linked_comp.id, title: "Linked"})
      _unlinked_story = story_fixture(scope, %{title: "Unlinked"})
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStoryLinkage.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "Linked Stories"
      assert content =~ "Unlinked Stories"
      assert content =~ "Orphan Components"
    end

    test "handles empty project" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = AnalyzeStoryLinkage.execute(%{}, frame)

      refute response.isError
      content = response_text(response)
      assert content =~ "All stories are linked"
    end

    test "returns error without valid scope" do
      frame = %Frame{assigns: %{}}

      assert {:reply, response, ^frame} = AnalyzeStoryLinkage.execute(%{}, frame)

      assert response.isError
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
