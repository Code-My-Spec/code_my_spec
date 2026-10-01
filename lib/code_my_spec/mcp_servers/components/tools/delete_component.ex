defmodule CodeMySpec.McpServers.Components.Tools.DeleteComponent do
  @moduledoc """
  Deletes a component and its spec file. Implementation and test files are left
  alone; while one still names the module, the next sync brings the component
  back.
  """

  # Components are projections of files (`Files.ComponentSync`). Deleting only
  # the row was undone by the next sync, which recreated it from the spec that
  # still named the module (issue 856b3632). So the spec goes too — it is the
  # component's own. Code and tests are somebody's work and are not touched;
  # the reply names them so the caller can decide.

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Architecture.SpecStub
  alias CodeMySpec.Components
  alias CodeMySpec.Environments
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
         files = owned_files(scope, component),
         {:ok, removed} <- remove_specs(scope, files.spec),
         {:ok, component} <- Components.delete_component(scope, component) do
      {:reply, reply(component, removed, files), frame}
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

  # The spec files the component was synced from, plus its conventional spec
  # path in case it has not been synced yet. Everything else it owns is kept.
  defp owned_files(scope, component) do
    {specs, others} =
      scope
      |> Files.list_component_files(component.id)
      |> Enum.split_with(&(&1.role == :spec))

    conventional = SpecStub.path_for(component.module_name)

    conventional =
      if Environments.file_exists?(scope.environment, conventional), do: [conventional], else: []

    %{
      spec: Enum.uniq(Enum.map(specs, & &1.path) ++ conventional),
      kept: others |> Enum.map(& &1.path) |> Enum.uniq() |> Enum.sort()
    }
  end

  # `{:ok, removed}` lists what came off disk; with no environment nothing can,
  # and the reply says which files to remove.
  defp remove_specs(%{environment: nil}, _paths), do: {:ok, []}

  defp remove_specs(scope, paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, removed} ->
      case Environments.delete_file(scope.environment, path) do
        :ok ->
          Files.delete_by_paths(scope, [path])
          {:cont, {:ok, [path | removed]}}

        {:error, reason} ->
          {:halt,
           {:error,
            "Could not remove the spec file #{path} (#{inspect(reason)}), so the component " <>
              "was not deleted. Removed before it: #{inspect(Enum.reverse(removed))}."}}
      end
    end)
    |> then(fn
      {:ok, removed} -> {:ok, Enum.reverse(removed)}
      error -> error
    end)
  end

  defp reply(component, removed, files) do
    Response.tool()
    |> Response.json(%{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description,
      spec_files_removed: removed,
      spec_files_to_remove: files.spec -- removed,
      files_left_in_place: files.kept,
      note: note(files.spec -- removed, files.kept)
    })
  end

  defp note([], []), do: "Deleted, with its spec file."

  defp note([], kept) do
    "Deleted, with its spec file. Its implementation and test files were left in place " <>
      "(#{Enum.join(kept, ", ")}); while one still names the module, the next sync " <>
      "recreates the component."
  end

  defp note(unremoved, _kept) do
    "Deleted the row, but this server has no working copy to remove the spec from. " <>
      "Delete #{Enum.join(unremoved, ", ")} yourself, or the next sync recreates the component."
  end
end
