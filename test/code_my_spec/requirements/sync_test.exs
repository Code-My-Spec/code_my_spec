defmodule CodeMySpec.Requirements.SyncTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.Sync

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.StoriesFixtures

  setup do
    scope = full_scope_fixture()
    {:ok, scope: scope}
  end

  describe "sync_requirements/6" do
    test "basic sync with changed components", %{scope: scope} do
      # Create a simple component
      _accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      # Load components with required associations
      components = Components.list_components(scope) |> Repo.preload([:project])

      # Mark first component as changed
      changed_ids = MapSet.new([hd(components).id])

      # Call sync_requirements with minimal setup
      result = Sync.sync_requirements(scope, components, changed_ids, [], [], [])

      # Should return list of components
      assert is_list(result)
      assert length(result) == 1
    end

    test "force option syncs all components", %{scope: scope} do
      # Create components
      _accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})
      _blog = component_fixture(scope, %{module_name: "MyApp.Blog", type: "context"})

      # Load components
      components = Components.list_components(scope) |> Repo.preload([:project])

      # Empty changed set but force=true
      changed_ids = MapSet.new()

      # Should process all components because of force flag
      result = Sync.sync_requirements(scope, components, changed_ids, [], [], force: true)

      assert is_list(result)
      assert length(result) == 2
    end
  end

  describe "sync_all_requirements/3" do
    test "syncs requirements for all components", %{scope: scope} do
      # Create components
      _accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      # Load and sync
      components = Components.list_components(scope) |> Repo.preload([:project])
      result = Sync.sync_all_requirements(components, scope)

      # Should return list with requirements
      assert is_list(result)
      assert length(result) == 1
    end
  end

  describe "cascade_from_components/2" do
    test "returns :ok immediately for empty component IDs", %{scope: scope} do
      assert :ok = Sync.cascade_from_components(scope, [])
    end

    test "creates story requirements for stories linked to changed components", %{scope: scope} do
      # Create a component and a story linked to it
      accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})
      _story = story_fixture(scope, %{component_id: accounts.id, title: "Manage accounts"})

      # Cascade from the changed component
      assert :ok = Sync.cascade_from_components(scope, [accounts.id])

      # Story should now have requirements (e.g., bdd_specs_exist, component_linked)
      {:ok, stories} = CodeMySpec.Stories.list_project_stories(scope)
      story = stories |> Repo.preload(:requirements) |> hd()
      assert length(story.requirements) > 0

      # Verify at least one story-level requirement was created
      story_req_names = Enum.map(story.requirements, & &1.name)
      assert "component_linked" in story_req_names
    end

    test "creates project requirements", %{scope: scope} do
      accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})

      assert :ok = Sync.cascade_from_components(scope, [accounts.id])

      # Project should now have requirements
      project = Repo.preload(scope.active_project, :requirements)
      assert length(project.requirements) > 0
    end

    test "only cascades to stories linked to changed components", %{scope: scope} do
      accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})
      blog = component_fixture(scope, %{module_name: "MyApp.Blog", type: "context"})

      _accounts_story = story_fixture(scope, %{component_id: accounts.id, title: "Manage accounts"})
      _blog_story = story_fixture(scope, %{component_id: blog.id, title: "Manage blog"})

      # Only cascade from accounts
      assert :ok = Sync.cascade_from_components(scope, [accounts.id])

      # Both stories exist but only accounts story should have requirements
      {:ok, stories} = CodeMySpec.Stories.list_project_stories(scope)
      stories = Repo.preload(stories, :requirements)

      accounts_story = Enum.find(stories, &(&1.component_id == accounts.id))
      blog_story = Enum.find(stories, &(&1.component_id == blog.id))

      assert length(accounts_story.requirements) > 0
      assert blog_story.requirements == []
    end

    test "is idempotent — running twice produces same result", %{scope: scope} do
      accounts = component_fixture(scope, %{module_name: "MyApp.Accounts", type: "context"})
      _story = story_fixture(scope, %{component_id: accounts.id, title: "Manage accounts"})

      # Run cascade twice
      assert :ok = Sync.cascade_from_components(scope, [accounts.id])
      assert :ok = Sync.cascade_from_components(scope, [accounts.id])

      # Should not duplicate requirements (clear + recreate pattern)
      {:ok, stories} = CodeMySpec.Stories.list_project_stories(scope)
      story = stories |> Repo.preload(:requirements) |> hd()
      req_names = Enum.map(story.requirements, & &1.name)
      assert req_names == Enum.uniq(req_names)
    end
  end
end
