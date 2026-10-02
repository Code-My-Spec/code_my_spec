defmodule CodeMySpec.McpServers.Components.Tools.CreateComponent do
  @moduledoc """
  Creates a single component, as a record marked `:authored`.

  The patch-mode alternative to rewriting the full architecture proposal: the
  architect adds one component at a time during incremental design. It used to
  write a stub spec file too, which was then the only way the component's
  dependencies could be recorded; `add_dependency` does that now, and no file
  is written (3aeb66cf, step 2).
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Types
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :name, :string, required: true

    field :type, {:enum, Types.all()},
      required: true,
      description: "Component type: #{Enum.join(Types.all(), ", ")}."

    field :module_name, :string, required: true
    field :description, :string, required: false
    field :parent_component_id, :string, required: false
  end

  @impl true
  @spec execute(any(), any()) :: {:reply, Anubis.Server.Response.t(), any()}
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_scope(frame),
         {:ok, component} <-
           Components.create_component(scope, Map.put(params, :provenance, :authored)) do
      {:reply, ComponentsMapper.component_response(component), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end
end
