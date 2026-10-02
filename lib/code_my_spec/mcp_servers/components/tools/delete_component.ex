defmodule CodeMySpec.McpServers.Components.Tools.DeleteComponent do
  @moduledoc """
  Deletes a component. Its files are left alone; while live code still names
  the module, the next sync discovers it again.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Components
  alias CodeMySpec.Files
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :id, :string, required: true
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         component <- Components.get_component!(scope, params.id),
         kept = owned_paths(scope, component),
         {:ok, component} <- Components.delete_component(scope, component) do
      {:reply, reply(component, kept), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  rescue
    Ecto.NoResultsError ->
      {:reply, ComponentsMapper.not_found_error(), frame}
  end

  defp owned_paths(scope, component) do
    scope
    |> Files.list_component_files(component.id)
    |> Enum.map(& &1.path)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp reply(component, kept) do
    Response.tool()
    |> Response.json(%{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description,
      files_left_in_place: kept,
      note: note(kept)
    })
  end

  defp note([]), do: "Deleted."

  defp note(kept) do
    "Deleted. Its files were left in place (#{Enum.join(kept, ", ")}); while code still " <>
      "names the module, the next sync discovers it again."
  end
end
