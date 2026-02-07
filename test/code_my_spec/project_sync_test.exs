defmodule CodeMySpec.ProjectSyncTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.ProjectSync
  alias CodeMySpec.Components
  alias CodeMySpec.Projects

  import CodeMySpec.UsersFixtures

  describe "sync_all/1 - integration test" do
    setup do
      # Create scope with project
      scope = full_scope_fixture()

      # Update project to use test_phoenix_project module name
      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{
          module_name: "TestPhoenixProject"
        })

      scope = %{scope | active_project: project}

      # Clone from pool
      {:ok, project_dir} =
        CodeMySpec.Support.TestAdapter.clone(
          scope,
          "https://github.com/johns10/test_phoenix_project.git"
        )

      on_exit(fn ->
        CodeMySpec.Support.TestAdapter.checkin(project_dir)
      end)

      {:ok, scope: scope, tmp_dir: project_dir}
    end

    test "syncs all contexts and components from filesystem", %{scope: scope, tmp_dir: tmp_dir} do
      # Perform initial sync
      assert {:ok, result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)

      # Verify we got a sync result
      assert is_list(result.contexts)
      assert is_integer(result.requirements_updated)
      assert is_list(result.errors)

      # Verify contexts were created in database
      contexts = Components.list_contexts(scope)
      assert length(contexts) > 0

      # Verify all contexts have valid types
      Enum.each(contexts, fn context ->
        assert context.type in ["context", "coordination_context", nil]
        assert not is_nil(context.module_name)
        assert String.starts_with?(context.module_name, "TestPhoenixProject")
      end)
    end

    test "syncs child components for each context", %{scope: scope, tmp_dir: tmp_dir} do
      # Perform initial sync
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)

      # Get all contexts
      contexts = Components.list_contexts(scope)

      # Verify each context has components synced (or at least checked)
      Enum.each(contexts, fn context ->
        children = Components.list_child_components(scope, context.id)
        # Some contexts may have no children, just verify structure is correct
        assert is_list(children)

        # If there are children, verify they have proper parent linkage
        Enum.each(children, fn child ->
          assert child.parent_component_id == context.id
          assert String.starts_with?(child.module_name, context.module_name)
        end)
      end)
    end

    test "calculates requirements for all components", %{scope: scope, tmp_dir: tmp_dir} do
      # Perform initial sync
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)

      # Get all components with their requirements loaded
      components = Components.list_components_with_dependencies(scope)

      # Verify components have requirements analyzed
      # Not all components will have requirements, but the structure should exist
      assert length(components) > 0

      Enum.each(components, fn component ->
        # Each component should have the requirements association loaded
        # (even if it's an empty list)
        assert Map.has_key?(component, :requirements)
      end)
    end

    test "handles project with spec files and implementation files", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      # Perform initial sync
      assert {:ok, result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)

      # Find contexts that have both spec and implementation
      contexts_with_type = Enum.filter(result.contexts, &(not is_nil(&1.type)))

      # Should have at least some contexts with specs
      assert length(contexts_with_type) > 0
    end

    test "is idempotent - multiple syncs produce same result", %{scope: scope, tmp_dir: tmp_dir} do
      # First sync
      assert {:ok, _result1} = ProjectSync.sync_all(scope, base_dir: tmp_dir, persist: true)
      contexts1 = Components.list_contexts(scope)
      context1_ids = Enum.map(contexts1, & &1.id) |> Enum.sort()

      # Second sync
      assert {:ok, _result2} = ProjectSync.sync_all(scope, base_dir: tmp_dir, persist: true)
      contexts2 = Components.list_contexts(scope)
      context2_ids = Enum.map(contexts2, & &1.id) |> Enum.sort()

      # Should have same contexts in database
      assert context1_ids == context2_ids
    end

    test "respects scope boundaries", %{scope: scope, tmp_dir: tmp_dir} do
      # Create another scope with different project
      other_scope = full_scope_fixture()

      # Sync first scope
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)
      contexts1 = Components.list_contexts(scope)

      # Verify other scope has no contexts
      contexts2 = Components.list_contexts(other_scope)

      assert length(contexts1) > 0
      assert length(contexts2) == 0
    end

    test "returns errors in result when issues occur", %{scope: scope, tmp_dir: tmp_dir} do
      # This test verifies the error collection mechanism works
      # Even if there are no errors, the errors list should be present
      assert {:ok, result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)
      assert Map.has_key?(result, :errors)
      assert is_list(result.errors)
    end

    test "syncs from both docs/spec and lib directories", %{scope: scope, tmp_dir: tmp_dir} do
      # Perform initial sync
      assert {:ok, result} = ProjectSync.sync_all(scope, base_dir: tmp_dir)

      # Get contexts
      contexts = result.contexts

      # At minimum, we should find contexts from the lib directory
      # (even if there are no spec files)
      assert length(contexts) > 0

      # Verify module names are extracted correctly
      Enum.each(contexts, fn context ->
        assert is_binary(context.module_name)
        assert context.module_name =~ ~r/^[A-Z][a-zA-Z0-9_.]*$/
      end)
    end

    test "removes stale contexts that no longer exist in filesystem", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      # First sync
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir, persist: true)

      # Manually create a fake context that doesn't exist in filesystem
      {:ok, fake_context} =
        Components.create_component(scope, %{
          name: "StaleContext",
          module_name: "TestPhoenixProject.StaleContext",
          type: "context"
        })

      assert Components.get_component(scope, fake_context.id) != nil

      # Second sync should remove it
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir, persist: true)

      # Verify fake context was removed
      assert Components.get_component(scope, fake_context.id) == nil
    end

    test "removes stale child components that no longer exist in filesystem", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      # First sync
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir, persist: true)

      # Get a context
      [context | _] = Components.list_contexts(scope)

      # Manually create a fake child component
      {:ok, fake_component} =
        Components.create_component(scope, %{
          name: "StaleComponent",
          module_name: "#{context.module_name}.StaleComponent",
          type: "schema",
          parent_component_id: context.id
        })

      assert Components.get_component(scope, fake_component.id) != nil

      # Second sync should remove it
      assert {:ok, _result} = ProjectSync.sync_all(scope, base_dir: tmp_dir, persist: true)

      # Verify fake component was removed
      assert Components.get_component(scope, fake_component.id) == nil
    end
  end
end
