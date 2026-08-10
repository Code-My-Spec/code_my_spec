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
      {:reply, reply_for(scope, component), frame}
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        {:reply, ComponentsMapper.validation_error(changeset), frame}

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  # The stub matters more than it looks. Dependency edges are read out of spec
  # files, and a component with no edges and no story link is an orphan — so a
  # missing stub is not untidiness, it is `architecture_designed` becoming
  # unsatisfiable.
  #
  # It used to be written through an environment invented from the server's
  # current directory when the scope had none, and the warning on failure was
  # swallowed with `:ok`. On the light harness that put this project's stubs in
  # the *server's* repository — drill 7 left eight of them there — while the
  # agent's own spec directory stayed empty and every component it created read
  # as an orphan. Nothing in the reply said so.
  #
  # So when this server cannot write, it says what to write and where. The agent
  # has the disk; it only ever needed to be told.
  defp reply_for(scope, component) do
    case SpecStub.write_for_scope(scope, component) do
      :ok ->
        ComponentsMapper.component_response(component)

      {:error, :no_working_copy} ->
        {path, body} = SpecStub.render(component)

        ComponentsMapper.component_response(component, """

        This server has no working copy, so the stub spec was not written. \
        Write it yourself — without it the component has no dependency edges \
        and will read as an orphan:

        `#{path}`

        ```markdown
        #{body}
        ```
        """)

      {:error, reason} ->
        Logger.warning(
          "[CreateComponent] Failed to write spec stub for #{component.module_name}: #{inspect(reason)}"
        )

        ComponentsMapper.component_response(component)
    end
  end
end
