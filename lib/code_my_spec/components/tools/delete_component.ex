defmodule CodeMySpec.Components.Tools.DeleteComponent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "delete_component"

  @impl true
  def description do
    """
    Deletes a component. Its files are left alone; while live code still names
    the module, the next sync discovers it again.
    """
  end

  @impl true
  def params do
    %{component_id: {:required, :string}}
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         component <- Components.get_component!(scope, params.component_id),
         kept = owned_paths(scope, component),
         {:ok, component} <- Components.delete_component(scope, component) do
      reply(component, kept)
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        ComponentsMapper.validation_error(changeset)

      {:error, atom} ->
        ComponentsMapper.error(atom)
    end
  rescue
    Ecto.NoResultsError ->
      ComponentsMapper.not_found_error()
  end

  defp owned_paths(scope, component) do
    scope
    |> Files.list_component_files(component.id)
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reply(component, kept) do
    {:ok,
     JSON.encode!(%{
       id: component.id,
       name: component.name,
       type: component.type,
       module_name: component.module_name,
       description: component.description,
       files_left_in_place: kept,
       note: note(kept)
     })}
  end

  defp note([]), do: "Deleted."

  defp note(kept) do
    "Deleted. Its files were left in place (#{Enum.join(kept, ", ")}); while code still " <>
      "names the module, the next sync discovers it again."
  end
end
