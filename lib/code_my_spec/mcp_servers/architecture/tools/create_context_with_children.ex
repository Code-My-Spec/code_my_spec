defmodule CodeMySpec.McpServers.Architecture.Tools.CreateContextWithChildren do
  @moduledoc """
  MCP tool for creating a bounded context with all its child components.

  Creates the context spec and all child component specs in a single operation.
  Optionally links stories to the components.
  """

  use Hermes.Server.Component, type: :tool

  alias CodeMySpec.Components
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories

  schema do
    field :module_name, :string, required: true
    field :description, :string
    field :story_ids, {:array, :integer}, default: []

    field :children, {:array, :map}, default: []
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, env} <- Environments.create(:cli),
         {:ok, context, children, spec_paths} <- create_context_and_children(scope, env, params) do
      Environments.destroy(env)
      {:reply, ArchitectureMapper.context_with_children_created(context, children, spec_paths), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp create_context_and_children(scope, env, params) do
    context_module = params.module_name
    context_description = params[:description] || "#{derive_name(context_module)} bounded context"

    # Create context spec
    context_spec_path = build_spec_path(context_module)
    context_spec_content = generate_context_template(context_module, context_description, params.children)

    with :ok <- Environments.write_file(env, context_spec_path, context_spec_content),
         {:ok, context} <- create_component(scope, context_module, "context", context_description) do
      # Link stories to context
      maybe_link_stories(scope, context, params[:story_ids])

      # Create children
      children_result =
        params.children
        |> Enum.reduce_while({:ok, [], [context_spec_path]}, fn child, {:ok, created, paths} ->
          child_module = "#{context_module}.#{child["name"] || child[:name]}"
          child_type = child["type"] || child[:type] || "schema"
          child_description = child["description"] || child[:description] || ""
          child_story_ids = child["story_ids"] || child[:story_ids] || []

          spec_path = build_spec_path(child_module)
          spec_content = generate_child_template(child_module, child_type, child_description)

          with :ok <- Environments.write_file(env, spec_path, spec_content),
               {:ok, component} <- create_component(scope, child_module, child_type, child_description) do
            maybe_link_stories(scope, component, child_story_ids)
            {:cont, {:ok, [component | created], [spec_path | paths]}}
          else
            {:error, reason} ->
              {:halt, {:error, "Failed to create #{child_module}: #{inspect(reason)}"}}
          end
        end)

      case children_result do
        {:ok, children, spec_paths} ->
          {:ok, context, Enum.reverse(children), Enum.reverse(spec_paths)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, reason} ->
        {:error, "Failed to create context #{context_module}: #{inspect(reason)}"}
    end
  end

  defp create_component(scope, module_name, type, description) do
    component_attrs = %{
      module_name: module_name,
      type: type,
      description: description,
      name: derive_name(module_name)
    }

    case Components.upsert_component(scope, component_attrs) do
      %{id: _} = component -> {:ok, component}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp maybe_link_stories(_scope, _component, nil), do: :ok
  defp maybe_link_stories(_scope, _component, []), do: :ok

  defp maybe_link_stories(scope, component, story_ids) do
    Enum.each(story_ids, fn story_id ->
      case Stories.get_story(scope, story_id) do
        nil -> :ok
        story -> Stories.set_story_component(scope, story, component.id)
      end
    end)
  end

  defp build_spec_path(module_name) do
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join(["docs/spec" | path_parts]) <> ".spec.md"
  end

  defp derive_name(module_name) do
    module_name
    |> String.split(".")
    |> List.last()
  end

  defp generate_context_template(module_name, description, children) do
    children_section =
      if children == [] do
        "None defined yet"
      else
        children
        |> Enum.map(fn child ->
          name = child["name"] || child[:name]
          type = child["type"] || child[:type] || "schema"
          "- `#{module_name}.#{name}` (#{type})"
        end)
        |> Enum.join("\n")
      end

    """
    # #{module_name}

    #{description}

    ## Type

    context

    ## Children

    #{children_section}

    ## Public API

    Define the public API functions this context exposes.

    ## Dependencies

    - None

    """
  end

  defp generate_child_template(module_name, type, description) do
    """
    # #{module_name}

    #{description || "No description provided"}

    ## Type

    #{type}

    ## Dependencies

    - None

    ## Functions

    """
  end
end
