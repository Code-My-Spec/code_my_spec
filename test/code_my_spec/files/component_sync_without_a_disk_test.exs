defmodule CodeMySpec.Files.ComponentSyncWithoutADiskTest do
  @moduledoc """
  Components synced from File records alone.

  On the light harness there is no working copy to read, and a file that
  cannot be read names nothing — so a full sync that pruned what it did not see
  would make "the server has no disk" and "delete the components" the same
  event. The identity is extracted during the scan, where the bytes are, and
  travels in the File record. These tests drive the sync with
  `execution_context: nil` to prove nothing reopens a file.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.File, as: FileRecord

  setup do
    scope = full_scope_fixture()
    %{scope: put_fixture_execution_context(scope, nil)}
  end

  defp scanned_code(scope, path, module_name) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :implementation,
      valid: true,
      validation_errors: %{"errors" => %{}, "data" => %{"module_name" => module_name}},
      module_name: module_name
    })
  end

  defp named?(scope, module_name),
    do: Enum.any?(Components.list_components(scope), &(&1.module_name == module_name))

  describe "syncing components with no environment" do
    test "code's stored identity is enough to create the component", %{scope: scope} do
      scanned_code(scope, "lib/my_app/widgets.ex", "MyApp.Widgets")

      assert {:ok, _} = ComponentSync.sync_from_files(scope)

      assert named?(scope, "MyApp.Widgets"),
             "the module name came off the File record — nothing here could have " <>
               "opened the file to find it"
    end

    test "a component is not pruned just because the server cannot read files", %{scope: scope} do
      scanned_code(scope, "lib/my_app/widgets.ex", "MyApp.Widgets")
      {:ok, _} = ComponentSync.sync_from_files(scope)

      assert {:ok, _} = ComponentSync.sync_from_files(scope)

      assert named?(scope, "MyApp.Widgets"),
             "an unreadable file and a deleted component must not be the same event"
    end
  end
end
