defmodule CodeMySpec.Components.Tools.ADeletedComponentStaysDeletedTest do
  @moduledoc """
  `delete_component` deletes the record, and the next sync does not bring it
  back unless code still names the module.

  Issue 856b3632: when components were projections of spec files, deleting the
  row was undone by the next sync. Components are records now (3aeb66cf), so a
  spec brings nothing back; only live code is discovered, and the reply says
  which files are left.
  """

  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Components
  alias CodeMySpec.Files.ComponentSync
  alias CodeMySpec.Files.File, as: FileRecord

  setup do
    scope = put_fixture_environment(full_scope_fixture(), nil)

    component =
      component_fixture(scope, %{
        name: "Widgets",
        module_name: "MyApp.Widgets",
        type: "context",
        provenance: :authored
      })

    %{scope: scope, component: component}
  end

  defp file_row!(scope, path, role) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: role,
      valid: true,
      validation_errors: %{"errors" => %{}, "data" => %{"module_name" => "MyApp.Widgets"}}
    })
  end

  defp widgets(scope),
    do: Enum.find(Components.list_components(scope), &(&1.module_name == "MyApp.Widgets"))

  defp delete(scope, component) do
    frame = %Frame{assigns: %{current_scope: scope}}

    response =
      ToolLibrary.run(
        "delete_component",
        %{component_id: component.id},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert {:ok, text} = response
    text
  end

  test "a spec naming it does not bring it back", %{scope: scope, component: component} do
    file_row!(scope, ".code_my_spec/spec/my_app/widgets.spec.md", :spec)

    delete(scope, component)
    {:ok, _} = ComponentSync.sync_from_files(scope)

    refute widgets(scope)
  end

  test "code naming it is discovered again, and the reply says so", %{
    scope: scope,
    component: component
  } do
    file_row!(scope, "lib/my_app/widgets.ex", :implementation)
    {:ok, _} = ComponentSync.sync_from_files(scope)

    said = delete(scope, component)
    {:ok, _} = ComponentSync.sync_from_files(scope)

    assert said =~ "lib/my_app/widgets.ex"
    assert %{provenance: :discovered} = widgets(scope)
  end
end
