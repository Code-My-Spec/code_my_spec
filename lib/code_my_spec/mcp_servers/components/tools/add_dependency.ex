defmodule CodeMySpec.McpServers.Components.Tools.AddDependency do
  @moduledoc """
  Records that one component depends on another.

  Components are authored as records (3aeb66cf), and their dependencies with
  them. Until this tool an edge could only arrive by a spec file's
  `## Dependencies` being synced, so an architecture designed through the tools
  had no way to say what depended on what.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :source_component_id, :string,
      required: true,
      description: "The component that depends on the other"

    field :target_component_id, :string,
      required: true,
      description: "The component it depends on"
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         {:ok, source} <- fetch(scope, params.source_component_id),
         {:ok, target} <- fetch(scope, params.target_component_id),
         {:ok, _dependency} <-
           Components.create_dependency(scope, %{
             source_component_id: source.id,
             target_component_id: target.id,
             provenance: :authored
           }) do
      {:reply,
       Response.tool()
       |> Response.text("`#{source.module_name}` now depends on `#{target.module_name}`."), frame}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, {:not_found, id}} ->
        {:reply, ComponentsMapper.error("No component #{id} in this project."), frame}
    end
  end

  # Scoped, because `create_dependency` is not: it would link two components in
  # any project.
  defp fetch(scope, id) do
    case Components.get_component(scope, id) do
      nil -> {:error, {:not_found, id}}
      component -> {:ok, component}
    end
  end
end
