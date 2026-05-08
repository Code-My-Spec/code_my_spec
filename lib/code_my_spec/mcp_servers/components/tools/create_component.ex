defmodule CodeMySpec.McpServers.Components.Tools.CreateComponent do
  @moduledoc """
  Creates a single component and writes a stub spec file at the conventional
  path.

  This is the patch-mode alternative to rewriting the full architecture
  proposal — the architect adds one component at a time during incremental
  design. The DB row is created and a stub spec is written; the spec body is
  left for the ComponentSpec phase to fill in.
  """

  use Anubis.Server.Component, type: :tool

  require Logger

  alias CodeMySpec.Architecture.SpecStub
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.ComponentsMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :name, :string, required: true

    field :type,
          {:enum,
           [
             "context",
             "coordination_context",
             "live_context",
             "schema",
             "behaviour",
             "json",
             "liveview",
             "liveview_component",
             "controller",
             "module"
           ]},
          required: true,
          description:
            "Component type: context, coordination_context, live_context, schema, behaviour, json, liveview, liveview_component, controller, or module."

    field :module_name, :string, required: true
    field :description, :string, required: false
    field :parent_component_id, :string, required: false
  end

  @impl true
  @spec execute(any(), any()) :: {:reply, Anubis.Server.Response.t(), any()}
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:ok, component} <- Components.create_component(scope, params) do
      write_stub(scope, component)
      {:reply, ComponentsMapper.component_response(component), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp write_stub(scope, component) do
    case SpecStub.write_for_scope(scope, component) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "[CreateComponent] Failed to write spec stub for #{component.module_name}: #{inspect(reason)}"
        )

        :ok
    end
  end
end
