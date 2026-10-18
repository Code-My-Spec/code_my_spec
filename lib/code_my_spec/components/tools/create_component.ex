defmodule CodeMySpec.Components.Tools.CreateComponent do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "create_component"

  @impl true
  def description do
    """
    Creates a single component, as a record marked `:authored`.

    The patch-mode alternative to rewriting the full architecture proposal: the
    architect adds one component at a time during incremental design. It used to
    write a stub spec file too, which was then the only way the component's
    dependencies could be recorded; `add_dependency` does that now, and no file
    is written (3aeb66cf, step 2).
    """
  end

  @impl true
  def params do
    %{
      name: {:required, :string},
      type:
        {:required,
         {:meta,
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
             "module",
             "infrastructure"
           ]},
          [
            description:
              "Component type: context, coordination_context, live_context, schema, behaviour, json, liveview, liveview_component, controller, module, infrastructure."
          ]}},
      description: :string,
      module_name: {:required, :string},
      parent_component_id: :string
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:ok, component} <-
           Components.create_component(scope, Map.put(params, :provenance, :authored)) do
      ComponentsMapper.component_response(component)
    else
      {:error, changeset = %Ecto.Changeset{}} ->
        ComponentsMapper.validation_error(changeset)

      {:error, atom} ->
        ComponentsMapper.error(atom)
    end
  end
end
