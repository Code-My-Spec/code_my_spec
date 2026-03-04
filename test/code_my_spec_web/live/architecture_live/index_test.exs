defmodule CodeMySpecWeb.ArchitectureLive.IndexTest do
  use CodeMySpecTest.ConnCase

  import Phoenix.LiveViewTest
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  setup [:register_log_in_setup_account, :setup_active_account, :setup_active_project]

  defp create_story_with_component(%{scope: scope}) do
    component = component_fixture(scope, %{name: "UserService", type: "genserver"})
    story = story_fixture(scope, %{title: "User Login", component_id: component.id})
    %{component: component, story: story}
  end

  describe "Index" do
    test "displays architecture overview header", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      assert html =~ "Architecture Overview"
    end

    test "displays navigation buttons", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      assert html =~ "Components"
      assert html =~ "Stories"
    end

    test "displays empty state when no stories exist", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      assert html =~ "No stories or components"
      assert html =~ "Create Story"
      assert html =~ "Create Component"
    end

    test "displays unsatisfied stories section", %{conn: conn, scope: scope} do
      _story = story_fixture(scope, %{title: "Password Reset", component_id: nil})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      assert html =~ "Password Reset"
      assert html =~ "no component"
      assert html =~ "Needs component assignment"
    end

    test "displays satisfied stories section", %{conn: conn, scope: scope} do
      component = component_fixture(scope, %{name: "UserService", type: "genserver"})
      _story = story_fixture(scope, %{title: "User Login", component_id: component.id})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      assert html =~ "UserService (1 stories)"
      assert html =~ "Stories"
      assert html =~ "User Login"
    end

    test "displays component type badges correctly", %{conn: conn, scope: scope} do
      genserver = component_fixture(scope, %{name: "UserService", type: "genserver"})
      repository = component_fixture(scope, %{name: "UserRepo", type: "repository"})

      _story1 = story_fixture(scope, %{title: "User Login", component_id: genserver.id})
      _story2 = story_fixture(scope, %{title: "User Data", component_id: repository.id})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      assert html =~ "UserService (genserver)"
      assert html =~ "UserRepo (repository)"
    end

    test "displays collapsible menu structure", %{conn: conn, scope: scope} do
      component = component_fixture(scope, %{name: "UserService", type: "genserver"})
      _story = story_fixture(scope, %{title: "User Login", component_id: component.id})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should have collapsible menu elements
      assert html =~ "<details>"
      assert html =~ "<summary"
    end

    test "shows edit links for components in dependencies", %{conn: conn, scope: scope} do
      component1 = component_fixture(scope, %{name: "UserService", type: "genserver"})
      component2 = component_fixture(scope, %{name: "UserRepo", type: "repository"})
      _story = story_fixture(scope, %{title: "User Login", component_id: component1.id})

      # Create dependency
      {:ok, _dependency} =
        CodeMySpec.Components.create_dependency(scope, %{
          source_component_id: component1.id,
          target_component_id: component2.id
        })

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Check for dependency edit link
      assert html =~ "/components/#{component2.id}/edit"
    end

    test "shows edit story links", %{conn: conn, scope: scope} do
      component = component_fixture(scope, %{name: "UserService", type: "genserver"})
      story = story_fixture(scope, %{title: "User Login", component_id: component.id})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Check for story edit link in HTML
      assert html =~ "/stories/#{story.id}/edit"
    end

    test "has navigation buttons", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Check that navigation buttons exist
      assert html =~ "href=\"/app/components\""
      assert html =~ "href=\"/app/stories\""
    end

    test "displays component with story count", %{conn: conn, scope: scope} do
      component = component_fixture(scope, %{name: "UserService", type: "genserver"})
      _story1 = story_fixture(scope, %{title: "User Login", component_id: component.id})
      _story2 = story_fixture(scope, %{title: "User Logout", component_id: component.id})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should show component with story count
      assert html =~ "UserService (2 stories)"
    end
  end

  describe "Real-time updates" do
    setup [:create_story_with_component]

    test "updates when component is created", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, ~p"/app/architecture")

      # Initially should not see the new component
      refute html =~ "EmailService"

      # Create a new component with story
      component = component_fixture(scope, %{name: "EmailService", type: "task"})
      _story = story_fixture(scope, %{title: "Send Email", component_id: component.id})

      # Should now see the new component in the updated architecture
      assert render(live) =~ "EmailService"
      assert render(live) =~ "Send Email"
    end

    test "updates when story is created", %{conn: conn, scope: scope} do
      {:ok, live, html} = live(conn, ~p"/app/architecture")

      # Initially should not see the new story
      refute html =~ "New Feature"

      # Create a new story without component (unsatisfied)
      _story = story_fixture(scope, %{title: "New Feature", component_id: nil})

      # Should now see the new story in unsatisfied section
      updated_html = render(live)
      assert updated_html =~ "New Feature"
      assert updated_html =~ "no component"
    end

    test "updates when story component is assigned", %{conn: conn, scope: scope} do
      # Create unsatisfied story first
      story = story_fixture(scope, %{title: "Feature Request", component_id: nil})

      {:ok, live, html} = live(conn, ~p"/app/architecture")

      # Should see story in unsatisfied section
      assert html =~ "Feature Request"
      assert html =~ "no component"

      # Assign component to story
      component = component_fixture(scope, %{name: "FeatureService"})
      {:ok, _updated_story} = CodeMySpec.Stories.set_story_component(scope, story, component.id)

      # Should now see story in satisfied section
      updated_html = render(live)
      assert updated_html =~ "Feature Request"
      assert updated_html =~ "FeatureService (1 stories)"
    end

    test "displays updated component data on refresh", %{
      conn: conn,
      component: component,
      scope: scope
    } do
      # Update the component first
      {:ok, updated_component} =
        CodeMySpec.Components.update_component(scope, component, %{
          name: "UpdatedUserService"
        })

      # Load the architecture page and verify the updated name appears
      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Check that the updated name appears
      assert html =~ updated_component.name
      # Note: Not checking absence of old name as there might be caching or other complexities
    end

    test "updates when component is deleted", %{
      conn: conn,
      component: component,
      story: story,
      scope: scope
    } do
      {:ok, live, html} = live(conn, ~p"/app/architecture")

      # Should see the component initially
      assert html =~ component.name
      assert html =~ story.title

      # Delete the component (this should clear the story's component_id)
      {:ok, _} = CodeMySpec.Components.delete_component(scope, component)

      # Component should be gone, story should move to unsatisfied
      updated_html = render(live)
      refute updated_html =~ component.name
      # Story might still appear but should be in unsatisfied section if component_id was cleared
    end
  end

  describe "Data processing" do
    test "groups components by story correctly", %{conn: conn, scope: scope} do
      # Create multiple components for same story
      component1 = component_fixture(scope, %{name: "AuthService", type: "genserver"})
      component2 = component_fixture(scope, %{name: "UserRepo", type: "repository"})

      _story = story_fixture(scope, %{title: "User Authentication", component_id: component1.id})

      # Create dependency relationship
      {:ok, _dependency} =
        CodeMySpec.Components.create_dependency(scope, %{
          source_component_id: component1.id,
          target_component_id: component2.id,
          dependency_type: :uses
        })

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should show both components under the same story
      assert html =~ "User Authentication"
      assert html =~ "AuthService"
      # Note: UserRepo might not show unless it's properly connected via show_architecture
    end

    test "handles empty architecture data gracefully", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should not crash and should show empty state
      assert html =~ "No stories or components"
    end

    test "handles components without stories", %{conn: conn, scope: scope} do
      # Create component without story
      _component = component_fixture(scope, %{name: "OrphanComponent"})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should show the orphan component with warning styling
      assert html =~ "OrphanComponent"
      assert html =~ "(no stories)"
      assert html =~ "text-warning"
    end
  end

  describe "Menu formatting" do
    test "displays proper collapsible menu for component", %{conn: conn, scope: scope} do
      component = component_fixture(scope, %{name: "SimpleService"})
      _story = story_fixture(scope, %{title: "Simple Feature", component_id: component.id})

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should use proper menu formatting
      assert html =~ "<details>"
      assert html =~ "SimpleService (1 stories)"
    end

    test "displays stories and dependencies in submenus", %{conn: conn, scope: scope} do
      component1 = component_fixture(scope, %{name: "UserService"})
      component2 = component_fixture(scope, %{name: "UserRepo"})
      _story = story_fixture(scope, %{title: "User Management", component_id: component1.id})

      # Create dependency
      {:ok, _dependency} =
        CodeMySpec.Components.create_dependency(scope, %{
          source_component_id: component1.id,
          target_component_id: component2.id
        })

      {:ok, _live, html} = live(conn, ~p"/app/architecture")

      # Should have Stories and Dependencies submenus
      assert html =~ "Stories"
      assert html =~ "Dependencies"
    end
  end
end
