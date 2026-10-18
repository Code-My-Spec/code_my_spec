defmodule CodeMySpec.Components.Tools.ContextStatisticsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.DependencyFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures
  import CodeMySpec.StoriesFixtures

  alias Anubis.Server.Frame

  describe "ContextStatistics tool" do
    setup do
      user = user_fixture()
      account = account_with_owner_fixture(user)
      scope = user_scope_fixture(user, account)
      project = project_fixture(scope)
      scope = user_scope_fixture(user, account, project)

      %{scope: scope}
    end

    test "returns empty statistics when no components exist", %{scope: scope} do
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "context_statistics",
          %{sort_by: "story_count"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {:ok, content_text} = response
      parsed = Jason.decode!(content_text)

      assert parsed["component_statistics"] == []
      assert parsed["summary"]["total_components"] == 0
    end

    test "returns statistics for components with stories and dependencies", %{scope: scope} do
      # Create components
      comp1 = component_fixture(scope, %{name: "Component1"})
      comp2 = component_fixture(scope, %{name: "Component2"})
      comp3 = component_fixture(scope, %{name: "Component3"})

      # Add stories
      story_fixture(scope, %{component_id: comp1.id})
      story_fixture(scope, %{component_id: comp1.id})
      story_fixture(scope, %{component_id: comp2.id})

      # Add dependencies
      dependency_fixture(scope, comp1, comp2)
      dependency_fixture(scope, comp2, comp3)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "context_statistics",
          %{sort_by: "story_count"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {:ok, content_text} = response
      parsed = Jason.decode!(content_text)

      stats = parsed["component_statistics"]
      assert length(stats) == 3

      # Should be sorted by story count (desc)
      assert hd(stats)["story_count"] == 2
      assert hd(stats)["component"]["name"] == "Component1"

      # Check summary
      summary = parsed["summary"]
      assert summary["total_components"] == 3
      assert summary["total_stories"] == 3
      assert summary["components_with_stories"] == 2
    end

    test "sorts by dependency count when requested", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Component1"})
      comp2 = component_fixture(scope, %{name: "Component2"})
      comp3 = component_fixture(scope, %{name: "Component3"})

      # comp2 will have most dependencies (1 out, 1 in = 2 total)
      dependency_fixture(scope, comp1, comp2)
      dependency_fixture(scope, comp2, comp3)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "context_statistics",
          %{sort_by: "dependency_count"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {:ok, content_text} = response
      parsed = Jason.decode!(content_text)

      stats = parsed["component_statistics"]

      # Should be sorted by total dependency count (desc)
      assert hd(stats)["component"]["name"] == "Component2"
      assert hd(stats)["dependency_counts"]["total"] == 2
    end

    test "calculates dependency counts correctly", %{scope: scope} do
      comp1 = component_fixture(scope, %{name: "Component1"})
      comp2 = component_fixture(scope, %{name: "Component2"})
      comp3 = component_fixture(scope, %{name: "Component3"})

      # comp2 depends on comp3 (outgoing)
      # comp1 depends on comp2 (comp2 has incoming)
      dependency_fixture(scope, comp1, comp2)
      dependency_fixture(scope, comp2, comp3)

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "context_statistics",
          %{sort_by: "story_count"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      {:ok, content_text} = response
      parsed = Jason.decode!(content_text)

      stats = parsed["component_statistics"]
      comp2_stats = Enum.find(stats, &(&1["component"]["name"] == "Component2"))

      assert comp2_stats["dependency_counts"]["outgoing"] == 1
      assert comp2_stats["dependency_counts"]["incoming"] == 1
      assert comp2_stats["dependency_counts"]["total"] == 2
    end

    test "handles scope validation errors" do
      frame = %Frame{assigns: %{}}

      response =
        ToolLibrary.run(
          "context_statistics",
          %{sort_by: "story_count"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert {_, _} = response
      assert match?({:error, _}, response)
    end

    test "defaults to story_count sorting" do
      scope = %{active_account_id: UUID.uuid4(), active_project_id: nil, active_project: nil}
      frame = %Frame{assigns: %{current_scope: scope}}

      # Test that it uses default when no sort_by provided
      _response =
        ToolLibrary.run(
          "context_statistics",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )
    end
  end
end
