defmodule CodeMySpec.Components.SyncTest do
  use CodeMySpec.DataCase, async: true

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Sync

  import CodeMySpec.UsersFixtures

  setup do
    scope = full_scope_fixture()
    tmp_dir = Path.join(System.tmp_dir!(), "sync_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)

    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    {:ok, scope: scope, tmp_dir: tmp_dir}
  end

  # --- Fixtures ---

  defp write_spec(tmp_dir, module_name, opts \\ []) do
    description = Keyword.get(opts, :description, "#{module_name} module.")
    path = module_to_spec_path(tmp_dir, module_name)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    # #{module_name}

    #{description}

    ## Functions

    ### list/0

    Lists items.

    ```elixir
    @spec list() :: list()
    ```

    **Process**:
    1. Return list

    **Test Assertions**:
    - returns list

    ## Dependencies

    - None
    """)

    path
  end

  defp write_impl(tmp_dir, module_name, opts \\ []) do
    declared_name = Keyword.get(opts, :declared_name, module_name)
    path = module_to_impl_path(tmp_dir, module_name)
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    defmodule #{declared_name} do
      @moduledoc "#{declared_name} module"
    end
    """)

    path
  end

  defp write_raw_file(tmp_dir, relative_path, content) do
    path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp module_to_spec_path(tmp_dir, module_name) do
    parts = module_name |> String.split(".") |> Enum.map(&Macro.underscore/1)
    Path.join([tmp_dir, "docs/spec" | parts]) <> ".spec.md"
  end

  defp module_to_impl_path(tmp_dir, module_name) do
    parts = module_name |> String.split(".") |> Enum.map(&Macro.underscore/1)
    Path.join([tmp_dir, "lib" | parts]) <> ".ex"
  end

  # --- Tests ---

  describe "sync_all/2" do
    test "uses implementation module name when present", %{scope: scope, tmp_dir: tmp_dir} do
      write_impl(tmp_dir, "MyApp.Accounts")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert length(components) == 1
      assert hd(components).module_name == "MyApp.Accounts"
    end

    test "falls back to spec module name when no implementation", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert length(components) == 1
      assert hd(components).module_name == "MyApp.Accounts"
    end

    test "falls back to path-derived name when neither declares module", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_raw_file(tmp_dir, "lib/my_app/utils/helpers.ex", "# no defmodule here")
      write_raw_file(tmp_dir, "docs/spec/my_app/utils/helpers.spec.md", "No H1 title here")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      matching = Enum.find(components, &(&1.module_name == "MyApp.Utils.Helpers"))
      assert matching != nil
    end

    test "uses declared module name even when path differs", %{scope: scope, tmp_dir: tmp_dir} do
      write_impl(tmp_dir, "MyApp.Accounts", declared_name: "MyApp.Users")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert length(components) == 1
      assert hd(components).module_name == "MyApp.Users"
    end

    test "creates separate components when spec and impl have different module names", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_impl(tmp_dir, "MyApp.Accounts", declared_name: "MyApp.UserAccounts")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      module_names = Enum.map(components, & &1.module_name)
      assert "MyApp.Accounts" in module_names
      assert "MyApp.UserAccounts" in module_names
    end

    test "finds all spec files recursively in docs/spec/", %{scope: scope, tmp_dir: tmp_dir} do
      for module <- [
            "MyApp.Accounts",
            "MyApp.Accounts.User",
            "MyApp.Accounts.Role",
            "MyApp.Blog.Post"
          ] do
        write_spec(tmp_dir, module)
      end

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      module_names = Enum.map(components, & &1.module_name)
      assert "MyApp.Accounts" in module_names
      assert "MyApp.Accounts.User" in module_names
      assert "MyApp.Accounts.Role" in module_names
      assert "MyApp.Blog.Post" in module_names
    end

    test "finds all impl files recursively in lib/", %{scope: scope, tmp_dir: tmp_dir} do
      for module <- [
            "MyApp.Accounts",
            "MyApp.Accounts.User",
            "MyApp.Accounts.Role",
            "MyApp.Blog.Post"
          ] do
        write_impl(tmp_dir, module)
      end

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      module_names = Enum.map(components, & &1.module_name)
      assert "MyApp.Accounts" in module_names
      assert "MyApp.Accounts.User" in module_names
      assert "MyApp.Accounts.Role" in module_names
      assert "MyApp.Blog.Post" in module_names
    end

    test "merges spec and impl data when both exist for same module", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_spec(tmp_dir, "MyApp.Accounts", description: "Description from spec file.")
      write_impl(tmp_dir, "MyApp.Accounts")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert length(components) == 1
      component = hd(components)
      assert component.module_name == "MyApp.Accounts"
      assert component.description =~ "Description from spec file"
    end

    test "creates components that don't exist", %{scope: scope, tmp_dir: tmp_dir} do
      assert Components.list_components(scope) == []

      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert length(components) == 1
      db_components = Components.list_components(scope)
      assert length(db_components) == 1
      assert hd(db_components).module_name == "MyApp.Accounts"
    end

    test "updates components that do exist (idempotent)", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts", description: "Original description.")

      {:ok, [first], _} = Sync.sync_all(scope, base_dir: tmp_dir)

      write_spec(tmp_dir, "MyApp.Accounts", description: "Updated description.")

      {:ok, [second], _} = Sync.sync_all(scope, base_dir: tmp_dir, force: true)

      assert second.id == first.id
      assert second.description =~ "Updated description"
    end

    test "derives parent relationships from module hierarchy", %{scope: scope, tmp_dir: tmp_dir} do
      for module <- ["MyApp.Accounts", "MyApp.Accounts.User", "MyApp.Accounts.Role"] do
        write_spec(tmp_dir, module)
      end

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      accounts = Enum.find(components, &(&1.module_name == "MyApp.Accounts"))

      user =
        Components.get_component(
          scope,
          Enum.find(components, &(&1.module_name == "MyApp.Accounts.User")).id
        )

      role =
        Components.get_component(
          scope,
          Enum.find(components, &(&1.module_name == "MyApp.Accounts.Role")).id
        )

      assert accounts.parent_component_id == nil
      assert user.parent_component_id == accounts.id
      assert role.parent_component_id == accounts.id
    end

    test "finds nearest ancestor when intermediate namespaces are missing", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      # Create hierarchy with missing intermediate namespace:
      # MyApp.Context exists, but MyApp.Context.Submodule does not
      # MyApp.Context.Submodule.Child should parent to MyApp.Context
      for module <- [
            "MyApp.Context",
            "MyApp.Context.Submodule.Child1",
            "MyApp.Context.Submodule.Child2"
          ] do
        write_spec(tmp_dir, module)
      end

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      context = Enum.find(components, &(&1.module_name == "MyApp.Context"))

      child1 =
        Components.get_component(
          scope,
          Enum.find(components, &(&1.module_name == "MyApp.Context.Submodule.Child1")).id
        )

      child2 =
        Components.get_component(
          scope,
          Enum.find(components, &(&1.module_name == "MyApp.Context.Submodule.Child2")).id
        )

      # Both children should have Context as parent (skipping missing Submodule)
      assert child1.parent_component_id == context.id
      assert child2.parent_component_id == context.id
    end

    test "finds nearest ancestor multiple levels up", %{scope: scope, tmp_dir: tmp_dir} do
      # Create deeply nested component with multiple missing intermediate namespaces
      # MyApp.Root exists, but MyApp.Root.A, MyApp.Root.A.B, MyApp.Root.A.B.C don't
      # MyApp.Root.A.B.C.Leaf should parent to MyApp.Root
      for module <- ["MyApp.Root", "MyApp.Root.A.B.C.Leaf"] do
        write_spec(tmp_dir, module)
      end

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      root = Enum.find(components, &(&1.module_name == "MyApp.Root"))

      leaf =
        Components.get_component(
          scope,
          Enum.find(components, &(&1.module_name == "MyApp.Root.A.B.C.Leaf")).id
        )

      assert leaf.parent_component_id == root.id
    end

    test "removes components no longer in filesystem", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")
      {:ok, _, _} = Sync.sync_all(scope, base_dir: tmp_dir)

      {:ok, orphan} =
        Components.create_component(scope, %{
          name: "Orphan",
          module_name: "MyApp.Orphan",
          type: "context"
        })

      assert Components.get_component(scope, orphan.id) != nil

      {:ok, _, _} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert Components.get_component(scope, orphan.id) == nil
    end

    test "respects scope boundaries", %{scope: scope, tmp_dir: tmp_dir} do
      other_scope = full_scope_fixture()
      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, components1, _} = Sync.sync_all(scope, base_dir: tmp_dir)
      {:ok, _, _} = Sync.sync_all(other_scope, base_dir: tmp_dir)

      assert length(components1) == 1

      first_components = Components.list_components(scope)
      other_components = Components.list_components(other_scope)

      assert hd(first_components).project_id == scope.active_project.id
      assert hd(other_components).project_id == other_scope.active_project.id
      assert hd(first_components).id != hd(other_components).id
    end

    test "skips files that have not been modified since last sync", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, [first], _} = Sync.sync_all(scope, base_dir: tmp_dir)
      Process.sleep(10)
      {:ok, [second], _} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert second.synced_at == first.synced_at
    end

    test "syncs files when mtime is newer than component synced_at", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      path = write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, [first], _} = Sync.sync_all(scope, base_dir: tmp_dir)

      Process.sleep(1100)
      File.touch!(path)

      {:ok, [second], _} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert DateTime.compare(second.synced_at, first.synced_at) == :gt
    end

    test "force option bypasses mtime check", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, [first], _} = Sync.sync_all(scope, base_dir: tmp_dir)
      Process.sleep(1100)
      {:ok, [second], _} = Sync.sync_all(scope, base_dir: tmp_dir, force: true)

      assert DateTime.compare(second.synced_at, first.synced_at) == :gt
    end

    test "handles files without module declarations gracefully", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Valid")
      write_raw_file(tmp_dir, "lib/my_app/helper.ex", "# just a comment")

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert Enum.any?(components, &(&1.module_name == "MyApp.Valid"))
      assert Enum.any?(components, &(&1.module_name == "MyApp.Helper"))
    end
  end

  describe "sync_changed/2" do
    test "returns all components and changed IDs on first sync", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_impl(tmp_dir, "MyApp.Accounts")

      {:ok, all_components, changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      assert length(all_components) == 1
      assert length(changed_ids) == 1
      assert hd(all_components).module_name == "MyApp.Accounts"
      assert hd(changed_ids) == hd(all_components).id
    end

    test "returns empty changed IDs when nothing changed", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, _, first_changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)
      assert length(first_changed_ids) == 1

      Process.sleep(10)
      {:ok, all_components, second_changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      assert length(all_components) == 1
      assert length(second_changed_ids) == 0
    end

    test "returns only changed component IDs when file is modified", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_spec(tmp_dir, "MyApp.Users")

      {:ok, _, first_changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)
      assert length(first_changed_ids) == 2

      Process.sleep(1100)
      accounts_path = module_to_spec_path(tmp_dir, "MyApp.Accounts")
      File.touch!(accounts_path)

      {:ok, all_components, second_changed_ids} =
        Sync.sync_changed(scope, base_dir: tmp_dir)

      assert length(all_components) == 2
      assert length(second_changed_ids) == 1

      changed_component = Enum.find(all_components, &(&1.id in second_changed_ids))
      assert changed_component.module_name == "MyApp.Accounts"
    end

    test "force option marks all components as changed", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_spec(tmp_dir, "MyApp.Users")

      {:ok, _, first_changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)
      assert length(first_changed_ids) == 2

      Process.sleep(10)

      {:ok, all_components, second_changed_ids} =
        Sync.sync_changed(scope, base_dir: tmp_dir, force: true)

      assert length(all_components) == 2
      assert length(second_changed_ids) == 2
    end
  end

  describe "update_parent_relationships/4" do
    test "updates parent relationships for changed components", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_spec(tmp_dir, "MyApp.Accounts.User")

      {:ok, all_components, changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      {:ok, expanded_ids} =
        Sync.update_parent_relationships(scope, all_components, changed_ids)

      # Both components should be in expanded set (both were created)
      assert length(expanded_ids) == 2

      accounts = Enum.find(all_components, &(&1.module_name == "MyApp.Accounts"))
      user = Enum.find(all_components, &(&1.module_name == "MyApp.Accounts.User"))

      # Verify parent relationship was set
      user_from_db = Components.get_component(scope, user.id)
      assert user_from_db.parent_component_id == accounts.id
    end

    test "expands changed set when parent is created", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      # First sync: create child without parent
      write_spec(tmp_dir, "MyApp.Accounts.User")

      {:ok, _, _} = Sync.sync_all(scope, base_dir: tmp_dir)

      # Second sync: add parent (child's parent relationship will change)
      Process.sleep(1100)
      write_spec(tmp_dir, "MyApp.Accounts")

      {:ok, all_components, changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      # Only parent changed (newly created)
      assert length(changed_ids) == 1
      accounts = Enum.find(all_components, &(&1.module_name == "MyApp.Accounts"))
      assert hd(changed_ids) == accounts.id

      {:ok, expanded_ids} =
        Sync.update_parent_relationships(scope, all_components, changed_ids)

      # Expanded set includes both parent and child (child's parent_component_id changed)
      assert length(expanded_ids) == 2
      assert accounts.id in expanded_ids

      user = Enum.find(all_components, &(&1.module_name == "MyApp.Accounts.User"))
      assert user.id in expanded_ids

      # Verify parent relationship was updated
      user_from_db = Components.get_component(scope, user.id)
      assert user_from_db.parent_component_id == accounts.id
    end

    test "does not expand changed set when unrelated components change", %{
      scope: scope,
      tmp_dir: tmp_dir
    } do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_spec(tmp_dir, "MyApp.Accounts.User")
      write_spec(tmp_dir, "MyApp.Blog")

      {:ok, _, _} = Sync.sync_all(scope, base_dir: tmp_dir)

      # Modify only Blog (unrelated to Accounts hierarchy)
      Process.sleep(1100)
      blog_path = module_to_spec_path(tmp_dir, "MyApp.Blog")
      File.touch!(blog_path)

      {:ok, all_components, changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      assert length(changed_ids) == 1

      {:ok, expanded_ids} =
        Sync.update_parent_relationships(scope, all_components, changed_ids)

      # Only Blog changed, no expansion
      assert length(expanded_ids) == 1
      blog = Enum.find(all_components, &(&1.module_name == "MyApp.Blog"))
      assert hd(expanded_ids) == blog.id
    end

    test "force option updates all relationships", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec(tmp_dir, "MyApp.Accounts")
      write_spec(tmp_dir, "MyApp.Accounts.User")
      write_spec(tmp_dir, "MyApp.Blog")

      {:ok, all_components, changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      {:ok, expanded_ids} =
        Sync.update_parent_relationships(scope, all_components, changed_ids, force: true)

      # Force mode: all components included
      assert length(expanded_ids) == 3
    end

    test "handles adding new child to existing hierarchy", %{scope: scope, tmp_dir: tmp_dir} do
      # First sync: just parent
      write_spec(tmp_dir, "MyApp.Accounts")
      {:ok, _, _} = Sync.sync_all(scope, base_dir: tmp_dir)

      # Second sync: add child
      Process.sleep(1100)
      write_spec(tmp_dir, "MyApp.Accounts.User")

      {:ok, all_components, changed_ids} = Sync.sync_changed(scope, base_dir: tmp_dir)

      # Only new child changed
      assert length(changed_ids) == 1
      user = Enum.find(all_components, &(&1.module_name == "MyApp.Accounts.User"))
      assert hd(changed_ids) == user.id

      {:ok, expanded_ids} =
        Sync.update_parent_relationships(scope, all_components, changed_ids)

      # Only child in expanded set (parent didn't change)
      assert length(expanded_ids) == 1
      assert user.id in expanded_ids

      # Verify parent relationship was set
      user_from_db = Components.get_component(scope, user.id)
      accounts = Enum.find(all_components, &(&1.module_name == "MyApp.Accounts"))
      assert user_from_db.parent_component_id == accounts.id
    end
  end

  describe "dependency syncing" do
    defp write_spec_with_deps(tmp_dir, module_name, deps) do
      deps_text =
        case deps do
          [] -> "- None"
          list -> Enum.map_join(list, "\n", &"- #{&1}")
        end

      path = module_to_spec_path(tmp_dir, module_name)
      File.mkdir_p!(Path.dirname(path))

      File.write!(path, """
      # #{module_name}

      #{module_name} module.

      ## Dependencies

      #{deps_text}

      ## Functions

      ### list/0

      Lists items.

      ```elixir
      @spec list() :: list()
      ```

      **Process**:
      1. Return list

      **Test Assertions**:
      - returns list
      """)

      path
    end

    test "syncs dependencies from spec files", %{scope: scope, tmp_dir: tmp_dir} do
      # Create target components first
      write_spec_with_deps(tmp_dir, "MyApp.Repo", [])
      write_spec_with_deps(tmp_dir, "MyApp.Accounts.User", [])

      # Create source component with dependencies
      write_spec_with_deps(tmp_dir, "MyApp.Accounts.UserRepository", [
        "MyApp.Repo",
        "MyApp.Accounts.User"
      ])

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      assert length(components) == 3

      # Verify dependencies were created
      user_repo = Enum.find(components, &(&1.module_name == "MyApp.Accounts.UserRepository"))
      deps = Components.list_component_dependencies(scope, user_repo.id)

      assert length(deps) == 2
      target_names = Enum.map(deps, & &1.target_component.module_name) |> Enum.sort()
      assert target_names == ["MyApp.Accounts.User", "MyApp.Repo"]
    end

    test "removes dependencies that are no longer declared", %{scope: scope, tmp_dir: tmp_dir} do
      # Initial sync with dependencies
      write_spec_with_deps(tmp_dir, "MyApp.Repo", [])
      write_spec_with_deps(tmp_dir, "MyApp.Accounts.User", [])
      write_spec_with_deps(tmp_dir, "MyApp.Accounts.UserRepository", [
        "MyApp.Repo",
        "MyApp.Accounts.User"
      ])

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)
      user_repo = Enum.find(components, &(&1.module_name == "MyApp.Accounts.UserRepository"))

      assert length(Components.list_component_dependencies(scope, user_repo.id)) == 2

      # Second sync: remove one dependency
      Process.sleep(1100)
      write_spec_with_deps(tmp_dir, "MyApp.Accounts.UserRepository", ["MyApp.Repo"])

      {:ok, _components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)

      deps = Components.list_component_dependencies(scope, user_repo.id)
      assert length(deps) == 1
      assert hd(deps).target_component.module_name == "MyApp.Repo"
    end

    test "skips self-referential dependencies", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec_with_deps(tmp_dir, "MyApp.Accounts", ["MyApp.Accounts"])

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)
      accounts = Enum.find(components, &(&1.module_name == "MyApp.Accounts"))

      # Should have no dependencies (self-reference filtered out)
      assert Components.list_component_dependencies(scope, accounts.id) == []
    end

    test "skips dependencies to non-existent modules", %{scope: scope, tmp_dir: tmp_dir} do
      write_spec_with_deps(tmp_dir, "MyApp.Accounts", ["MyApp.NonExistent"])

      {:ok, components, _errors} = Sync.sync_all(scope, base_dir: tmp_dir)
      accounts = Enum.find(components, &(&1.module_name == "MyApp.Accounts"))

      # Should have no dependencies (target doesn't exist)
      assert Components.list_component_dependencies(scope, accounts.id) == []
    end
  end
end
