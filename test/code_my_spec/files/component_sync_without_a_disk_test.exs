defmodule CodeMySpec.Files.ComponentSyncWithoutADiskTest do
  @moduledoc """
  Components synced from File records alone.

  This is the failure mode `ComponentSync`'s own moduledoc warns about, reached
  by a different route. A spec it cannot parse yields no component; a full sync
  then prunes components it did not see. So on the light harness — where there
  is no working copy to read — "the server has no disk" and "delete the
  architecture" were the same event.

  The identity is extracted during the scan now, where the bytes are, and
  travels in the File record. These tests drive the sync with `environment: nil`
  to prove nothing reopens a file.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Components
  alias CodeMySpec.Files.{ComponentExtract, ComponentSync}
  alias CodeMySpec.Files.File, as: FileRecord

  @spec_body """
  # MyApp.Widgets

  Stores widgets for later.

  ## Type
  context

  ## Dependencies
  - MyApp.Repo
  """

  setup do
    scope = full_scope_fixture()
    %{scope: %{scope | environment: nil}}
  end

  defp sync_spec(scope, path, content) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: :spec,
      valid: true,
      validation_errors: %{
        "errors" => %{},
        "data" => %{
          "module_name" => ComponentExtract.extract_h1_module(content),
          "type" => ComponentExtract.extract_type_section(content),
          "description" => ComponentExtract.extract_intro_text(content),
          "dependencies" => ComponentExtract.extract_dependencies(content)
        }
      }
    })
  end

  describe "syncing components with no environment" do
    test "a spec's stored identity is enough to create the component", %{scope: scope} do
      sync_spec(scope, ".code_my_spec/spec/my_app/widgets.md", @spec_body)

      assert {:ok, result} = ComponentSync.sync_from_files(scope)

      assert Enum.any?(result.all_components, &(&1.module_name == "MyApp.Widgets")),
             "the module name came off the File record — nothing here could have " <>
               "opened the spec to find it"

      component =
        Enum.find(Components.list_components(scope), &(&1.module_name == "MyApp.Widgets"))

      assert to_string(component.type) == "context"
      assert component.description =~ "Stores widgets"
    end

    test "a component is not pruned just because the server cannot read files", %{scope: scope} do
      sync_spec(scope, ".code_my_spec/spec/my_app/widgets.md", @spec_body)
      {:ok, _} = ComponentSync.sync_from_files(scope)

      # Second pass over the same records, still with no disk. This is the one
      # that used to destroy architecture: the spec read as unparseable, the
      # component was absent from the merge, and cleanup_removed deleted it.
      assert {:ok, _} = ComponentSync.sync_from_files(scope)

      assert Enum.any?(Components.list_components(scope), &(&1.module_name == "MyApp.Widgets")),
             "an unreadable spec and a deleted component must not be the same event"
    end

    test "a CRLF spec still names its component", %{scope: scope} do
      crlf = String.replace(@spec_body, "\n", "\r\n")
      sync_spec(scope, ".code_my_spec/spec/my_app/widgets.md", crlf)

      assert {:ok, result} = ComponentSync.sync_from_files(scope)

      assert Enum.any?(result.all_components, &(&1.module_name == "MyApp.Widgets")),
             "the `$`-anchored extractors do not match across a \\r, and a spec " <>
               "that names nothing gets its component pruned — the regression " <>
               "ComponentSync was bitten by once"
    end
  end
end
