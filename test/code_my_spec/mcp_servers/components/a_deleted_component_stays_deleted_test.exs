defmodule CodeMySpec.McpServers.Components.ADeletedComponentStaysDeletedTest do
  @moduledoc """
  `delete_component` removes what the component is projected from, so the next
  sync does not bring it back.

  Issue 856b3632. Components are projections of files: deleting only the row
  left `.code_my_spec/spec/…/<name>.spec.md` in place, and the next
  `ComponentSync` recreated the component from it. The delete looked like it
  worked and undid itself.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.Files.{ComponentExtract, ComponentSync}
  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.McpServers.Components.Tools.DeleteComponent

  @spec_path ".code_my_spec/spec/my_app/widgets.spec.md"
  @impl_path "lib/my_app/widgets.ex"

  @spec_body """
  # MyApp.Widgets

  Stores widgets for later.

  ## Type
  context
  """

  @impl_body """
  defmodule MyApp.Widgets do
  end
  """

  setup do
    scope = full_scope_fixture()
    :ok = Environments.write_file(scope.environment, @spec_path, @spec_body)
    file_row!(scope, @spec_path, :spec, @spec_body)

    {:ok, _} = ComponentSync.sync_from_files(scope)

    %{scope: scope, component: widgets(scope)}
  end

  # A scanned file row, carrying the identity the scanner stores, so the sync
  # reads it the way it reads a real working copy's.
  defp file_row!(scope, path, role, content) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      working_copy_id: scope.active_working_copy_id,
      path: path,
      role: role,
      valid: true,
      validation_errors: %{
        "errors" => %{},
        "data" => %{
          "module_name" => module_name(role, content),
          "type" => ComponentExtract.extract_type_section(content),
          "description" => ComponentExtract.extract_intro_text(content),
          "dependencies" => []
        }
      }
    })
  end

  defp module_name(:spec, content), do: ComponentExtract.extract_h1_module(content)
  defp module_name(:implementation, _content), do: "MyApp.Widgets"

  defp widgets(scope),
    do: Enum.find(Components.list_components(scope), &(&1.module_name == "MyApp.Widgets"))

  defp delete(scope, component) do
    frame = %Frame{assigns: %{current_scope: scope}}
    {:reply, response, ^frame} = DeleteComponent.execute(%{id: component.id}, frame)
    response
  end

  defp text(response), do: Enum.map_join(response.content, "\n", & &1["text"])

  test "the premise: the spec projects the component", %{component: component} do
    assert component, "the sync did not create the component from its spec"
  end

  test "the next sync does not recreate a deleted component", %{
    scope: scope,
    component: component
  } do
    response = delete(scope, component)
    refute response.isError

    {:ok, _} = ComponentSync.sync_from_files(scope)

    refute widgets(scope),
           "the component came back on the next sync. Its spec file still named the " <>
             "module, so deleting the row was undone by the projection it came from."
  end

  test "its spec file is removed and the reply says so", %{scope: scope, component: component} do
    said = scope |> delete(component) |> text()

    refute Environments.file_exists?(scope.environment, @spec_path)
    assert said =~ @spec_path
  end

  test "implementation files are left alone, and the reply says so", %{
    scope: scope,
    component: component
  } do
    :ok = Environments.write_file(scope.environment, @impl_path, @impl_body)
    file_row!(scope, @impl_path, :implementation, @impl_body)
    {:ok, _} = ComponentSync.sync_from_files(scope)

    said = scope |> delete(component) |> text()

    assert Environments.file_exists?(scope.environment, @impl_path),
           "delete_component removed an implementation file. Only the spec is the " <>
             "component's own; code is somebody's work."

    assert said =~ @impl_path
  end
end
