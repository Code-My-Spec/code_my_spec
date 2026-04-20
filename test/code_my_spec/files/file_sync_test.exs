defmodule CodeMySpec.Files.FileSyncTest do
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Projects

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "classify/1" do
    test "classifies implementation files" do
      assert {:implementation, _} = swap(FileSync.classify("lib/my_app/accounts.ex"))
    end

    test "classifies test files" do
      assert {:test, _} = swap(FileSync.classify("test/my_app/accounts_test.exs"))
    end

    test "classifies spec files" do
      assert {:spec, _} = swap(FileSync.classify(".code_my_spec/spec/my_app/accounts.spec.md"))
    end

    test "classifies bdd spec files" do
      assert {:bdd_spec, _} = swap(FileSync.classify("test/spex/my_app/accounts_spex.exs"))
    end

    test "classifies rule files" do
      assert {:rule, _} = swap(FileSync.classify(".code_my_spec/rules/context.md"))
    end

    test "classifies qa brief files" do
      assert {:qa_brief, _} = swap(FileSync.classify(".code_my_spec/qa/440/brief.md"))
    end

    test "classifies qa result files" do
      assert {:qa_result, _} = swap(FileSync.classify(".code_my_spec/qa/440/result_complete.md"))
      assert {:qa_result, _} = swap(FileSync.classify(".code_my_spec/qa/440/result_failed_20260318_041104.md"))
      assert {:qa_result, _} = swap(FileSync.classify(".code_my_spec/qa/440/result.md"))
    end

    test "does not classify qa screenshots" do
      assert is_nil(FileSync.classify(".code_my_spec/qa/440/screenshots/01_page.png"))
    end

    test "classifies CLAUDE.md as config" do
      assert {:config, _} = swap(FileSync.classify("CLAUDE.md"))
    end

    test "classifies config.yml as config" do
      assert {:config, _} = swap(FileSync.classify(".code_my_spec/config.yml"))
    end

    test "returns nil for unrecognized files" do
      assert is_nil(FileSync.classify("README.md"))
      assert is_nil(FileSync.classify("mix.exs"))
      assert is_nil(FileSync.classify("assets/js/app.js"))
    end

    test "returns nil for files in ignored dirs" do
      # These would be filtered by ignored_path? before classify,
      # but classify itself doesn't match them either
      assert is_nil(FileSync.classify("deps/phoenix/lib/phoenix.ex"))
    end

    # Swap {path, role} to {role, path} for pattern matching on role
    defp swap({path, role}), do: {role, path}
    defp swap(nil), do: nil
  end

  describe "sync/2" do
    test "scans filesystem and creates File records" do
      {scope, tmp_dir} = setup_project()

      # Seed some files
      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts.spec.md", "# MyApp.Accounts\n\n## Type\n\nschema")
      write_file(tmp_dir, "CLAUDE.md", "# Project")

      {:ok, result} = FileSync.sync(scope, base_dir: tmp_dir)

      assert result.total_files >= 3
      assert result.upserted >= 3

      files = Files.list_files(scope)
      paths = Enum.map(files, & &1.path)

      assert "lib/my_app/accounts.ex" in paths
      assert ".code_my_spec/spec/my_app/accounts.spec.md" in paths
      assert "CLAUDE.md" in paths
    end

    test "full sync always reports all paths" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      {:ok, result1} = FileSync.sync(scope, base_dir: tmp_dir)
      assert "lib/my_app/accounts.ex" in result1.changed_paths

      # Second sync reports all paths too (no mtime filtering)
      {:ok, result2} = FileSync.sync(scope, base_dir: tmp_dir)
      assert "lib/my_app/accounts.ex" in result2.changed_paths
    end

    test "removes files that no longer exist on disk" do
      {scope, tmp_dir} = setup_project()

      path = write_file(tmp_dir, "lib/my_app/old.ex", "defmodule MyApp.Old do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      assert Files.get_by_path(scope, "lib/my_app/old.ex")

      # Delete the file
      File.rm!(path)

      {:ok, result} = FileSync.sync(scope, base_dir: tmp_dir)
      assert result.removed >= 1
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end

    test "assigns component_id to implementation files" do
      {scope, tmp_dir} = setup_project()

      # Create a component in DB
      {:ok, component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Accounts",
          type: "schema",
          module_name: "MyApp.Accounts"
        })

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      write_file(tmp_dir, ".code_my_spec/spec/my_app/accounts.spec.md", "# MyApp.Accounts\n\n## Type\n\nschema")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      impl_file = Files.get_by_path(scope, "lib/my_app/accounts.ex")
      assert impl_file.component_id == component.id
      assert impl_file.role == :implementation

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/accounts.spec.md")
      assert spec_file.component_id == component.id
      assert spec_file.role == :spec
    end

    test "validates spec files during sync" do
      {scope, tmp_dir} = setup_project()

      # Valid liveview spec with required sections
      spec_content = """
      # MyApp.UserLive.Index

      A page listing users.

      ## Type

      liveview

      ## Route

      `/users`

      ## User Interactions

      - **phx-click=delete**: Deletes a user

      ## Dependencies

      - MyApp.Users

      ## Design

      Layout: Table of users.
      """

      write_file(tmp_dir, ".code_my_spec/spec/my_app/user_live/index.spec.md", spec_content)
      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/user_live/index.spec.md")
      assert spec_file.valid == true
      assert spec_file.validation_errors == nil

      impl_file = Files.get_by_path(scope, "lib/my_app/accounts.ex")
      assert impl_file.valid == true
    end

    test "sets valid false for invalid spec files" do
      {scope, tmp_dir} = setup_project()

      # Spec missing required sections
      write_file(tmp_dir, ".code_my_spec/spec/my_app/broken.spec.md", "# MyApp.Broken\n\n## Type\n\nschema\n")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      spec_file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/broken.spec.md")
      assert spec_file.valid == false
      assert spec_file.validation_errors != nil
    end

    test "validates test files against spec test assertions" do
      {scope, tmp_dir} = setup_project()

      spec_content = """
      # MyApp.UserLive.Index

      A page listing users.

      ## Type

      liveview

      ## Route

      `/users`

      ## User Interactions

      - **phx-click=delete**: Deletes a user

      ## Dependencies

      - MyApp.Users

      ## Design

      Layout: Table of users.

      ## Test Assertions

      - renders user list
      - deletes user on click
      """

      # Test names must match the spec's Test Assertions lines. SpecAlignment
      # pulls `{:test, _, [name, ...]}` nodes from the AST; describe block names
      # aren't considered matchable.
      aligned_test = """
      defmodule MyApp.UserLive.IndexTest do
        use ExUnit.Case

        test "renders user list" do
          assert true
        end

        test "deletes user on click" do
          assert true
        end
      end
      """

      # Create component so test file gets component_id
      {:ok, component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Index",
          type: "liveview",
          module_name: "MyApp.UserLive.Index"
        })

      write_file(tmp_dir, ".code_my_spec/spec/my_app/user_live/index.spec.md", spec_content)
      write_file(tmp_dir, "test/my_app/user_live/index_test.exs", aligned_test)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      test_file = Files.get_by_path(scope, "test/my_app/user_live/index_test.exs")
      assert test_file.component_id == component.id
      assert test_file.valid == true
    end

    test "marks test file invalid when spec assertions are missing" do
      {scope, tmp_dir} = setup_project()

      spec_content = """
      # MyApp.UserLive.Show

      Shows a user.

      ## Type

      liveview

      ## Route

      `/users/:id`

      ## User Interactions

      - **phx-click=edit**: Opens edit form

      ## Dependencies

      - MyApp.Users

      ## Design

      Layout: Detail view.

      ## Test Assertions

      - renders user details
      - opens edit form on click
      - handles missing user
      """

      # Test only covers one of three assertions
      partial_test = """
      defmodule MyApp.UserLive.ShowTest do
        use ExUnit.Case

        describe "renders user details" do
          test "shows user" do
            assert true
          end
        end
      end
      """

      {:ok, _component} =
        CodeMySpec.Components.create_component(scope, %{
          name: "Show",
          type: "liveview",
          module_name: "MyApp.UserLive.Show"
        })

      write_file(tmp_dir, ".code_my_spec/spec/my_app/user_live/show.spec.md", spec_content)
      write_file(tmp_dir, "test/my_app/user_live/show_test.exs", partial_test)

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      test_file = Files.get_by_path(scope, "test/my_app/user_live/show_test.exs")
      assert test_file.valid == false
      assert "opens edit form on click" in test_file.validation_errors["missing"]
      assert "handles missing user" in test_file.validation_errors["missing"]
    end

    test "ignores deps, _build, .git directories" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "deps/phoenix/lib/phoenix.ex", "defmodule Phoenix do\nend")
      write_file(tmp_dir, "_build/dev/lib/my_app.ex", "defmodule MyApp do\nend")
      write_file(tmp_dir, "lib/my_app/real.ex", "defmodule MyApp.Real do\nend")

      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      files = Files.list_files(scope)
      paths = Enum.map(files, & &1.path)

      assert "lib/my_app/real.ex" in paths
      refute Enum.any?(paths, &String.starts_with?(&1, "deps/"))
      refute Enum.any?(paths, &String.starts_with?(&1, "_build/"))
    end
  end

  describe "sync_changed/2" do
    test "skips unchanged files and only upserts new or modified ones" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      write_file(tmp_dir, "lib/my_app/users.ex", "defmodule MyApp.Users do\nend")

      # Full sync to populate DB
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      # Second sync with no changes — nothing should be upserted
      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.upserted == 0
      assert result.changed_paths == []
      assert result.total_files >= 2

      # Touch one file to bump mtime
      :timer.sleep(1100)
      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\n  # changed\nend")

      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.upserted == 1
      assert "lib/my_app/accounts.ex" in result.changed_paths
      refute "lib/my_app/users.ex" in result.changed_paths
    end

    test "picks up new files not yet in DB" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)

      # Add a new file
      write_file(tmp_dir, "lib/my_app/users.ex", "defmodule MyApp.Users do\nend")

      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.upserted == 1
      assert "lib/my_app/users.ex" in result.changed_paths
    end

    test "removes files no longer on disk" do
      {scope, tmp_dir} = setup_project()

      path = write_file(tmp_dir, "lib/my_app/old.ex", "defmodule MyApp.Old do\nend")
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      assert Files.get_by_path(scope, "lib/my_app/old.ex")

      File.rm!(path)

      {:ok, result} = FileSync.sync_changed(scope, base_dir: tmp_dir)
      assert result.removed >= 1
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end
  end

  describe "sync_path/3" do
    test "processes a single path" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "lib/my_app/accounts.ex", "defmodule MyApp.Accounts do\nend")
      write_file(tmp_dir, "lib/my_app/users.ex", "defmodule MyApp.Users do\nend")

      abs_path = Path.join(tmp_dir, "lib/my_app/accounts.ex")
      {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      assert result.changed_path == "lib/my_app/accounts.ex"

      # Only accounts.ex should be in DB
      assert Files.get_by_path(scope, "lib/my_app/accounts.ex")
      refute Files.get_by_path(scope, "lib/my_app/users.ex")
    end

    test "deletes file record when file no longer exists on disk" do
      {scope, tmp_dir} = setup_project()

      path = write_file(tmp_dir, "lib/my_app/old.ex", "defmodule MyApp.Old do\nend")

      # First create the record via full sync
      {:ok, _} = FileSync.sync(scope, base_dir: tmp_dir)
      assert Files.get_by_path(scope, "lib/my_app/old.ex")

      # Delete from disk, then sync_path
      File.rm!(path)
      {:ok, result} = FileSync.sync_path(scope, path, base_dir: tmp_dir)

      assert result.changed_path == "lib/my_app/old.ex"
      refute Files.get_by_path(scope, "lib/my_app/old.ex")
    end

    test "returns nil changed_path for unrecognized file types" do
      {scope, tmp_dir} = setup_project()

      write_file(tmp_dir, "README.md", "# My App")
      abs_path = Path.join(tmp_dir, "README.md")

      {:ok, result} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      assert result.changed_path == nil
    end

    test "validates spec files" do
      {scope, tmp_dir} = setup_project()

      # Invalid spec — missing required sections
      write_file(tmp_dir, ".code_my_spec/spec/my_app/broken.spec.md", "# MyApp.Broken\n\n## Type\n\nschema\n")
      abs_path = Path.join(tmp_dir, ".code_my_spec/spec/my_app/broken.spec.md")

      {:ok, _} = FileSync.sync_path(scope, abs_path, base_dir: tmp_dir)

      file = Files.get_by_path(scope, ".code_my_spec/spec/my_app/broken.spec.md")
      assert file.valid == false
      assert file.validation_errors != nil
    end
  end

  # -- Helpers --

  defp setup_project do
    {:ok, tmp_dir} = Briefly.create(directory: true)
    scope = full_scope_fixture()
    {:ok, project} = Projects.update_project(scope, scope.active_project, %{local_path: tmp_dir})

    scope = %{
      scope
      | active_project: project,
        cwd: tmp_dir,
        environment: Environment.new(:local, tmp_dir)
    }

    {scope, tmp_dir}
  end

  defp write_file(tmp_dir, relative_path, content) do
    full_path = Path.join(tmp_dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    full_path
  end
end
