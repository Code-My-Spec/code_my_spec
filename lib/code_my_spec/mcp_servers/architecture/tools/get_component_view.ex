defmodule CodeMySpec.McpServers.Architecture.Tools.GetComponentView do
  @moduledoc """
  Generates detailed markdown view of a component and its full dependency tree.

  Shows component metadata, description, dependencies (outgoing), dependents (incoming),
  child components, and related stories. Useful for understanding a component's place
  in the architecture and its relationships.
  """

  use Hermes.Server.Component, type: :tool

  import Ecto.Query

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Component, as: ComponentSchema
  alias CodeMySpec.McpServers.Architecture.ArchitectureMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Repo

  schema do
    field :module_name, :string
    field :component_id, :string
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_project_scope(frame),
         {:ok, component} <- find_component(scope, params),
         {:ok, component_full} <- load_component_details(scope, component.id) do
      markdown = build_component_view(component_full)

      {:reply, ArchitectureMapper.component_view_response(markdown), frame}
    else
      {:error, reason} ->
        {:reply, ArchitectureMapper.error(reason), frame}
    end
  end

  defp load_component_details(scope, component_id) do
    # Load component with all needed associations
    query =
      from(c in ComponentSchema,
        where: c.id == ^component_id and c.project_id == ^scope.active_project_id,
        preload: [
          :parent_component,
          :child_components,
          :stories,
          outgoing_dependencies: :target_component,
          incoming_dependencies: :source_component
        ]
      )

    case Repo.one(query) do
      nil -> {:error, "Component not found"}
      component -> {:ok, component}
    end
  end

  defp find_component(scope, %{component_id: id}) when not is_nil(id) do
    case Components.get_component(scope, id) do
      nil -> {:error, "Component not found with id: #{id}"}
      component -> {:ok, component}
    end
  end

  defp find_component(scope, %{module_name: module_name}) when not is_nil(module_name) do
    case Components.get_component_by_module_name(scope, module_name) do
      nil -> {:error, "Component not found with module_name: #{module_name}"}
      component -> {:ok, component}
    end
  end

  defp find_component(_scope, _params) do
    {:error, "Must provide either component_id or module_name"}
  end

  defp build_component_view(component) do
    """
    # #{component.name}

    **Type:** #{component.type}
    **Module:** #{component.module_name}
    #{if component.description, do: "**Description:** #{component.description}\n", else: ""}
    ## Metadata

    - **ID:** #{component.id}
    - **Type:** #{component.type}
    - **Parent:** #{format_parent(component)}
    - **Created:** #{format_datetime(component.inserted_at)}
    - **Updated:** #{format_datetime(component.updated_at)}

    ## Dependencies (Outgoing)

    #{format_outgoing_dependencies(component.outgoing_dependencies)}

    ## Dependents (Incoming)

    #{format_incoming_dependencies(component.incoming_dependencies)}

    ## Child Components

    #{format_child_components(component.child_components)}

    ## Related Stories

    #{format_stories(component.stories)}

    ## Dependency Tree

    #{format_dependency_tree(component)}
    """
  end

  defp format_parent(component) do
    case component.parent_component do
      %Ecto.Association.NotLoaded{} -> "None (top-level)"
      nil -> "None (top-level)"
      parent -> "#{parent.name} (#{parent.module_name})"
    end
  end

  defp format_datetime(nil), do: "N/A"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")

  defp format_outgoing_dependencies([]), do: "_This component depends on: None_"

  defp format_outgoing_dependencies(dependencies) do
    dependencies
    |> Enum.map(fn dep ->
      target = dep.target_component
      "- **#{target.name}** (#{target.type}) - `#{target.module_name}`"
    end)
    |> Enum.join("\n")
  end

  defp format_incoming_dependencies([]), do: "_Components that depend on this: None_"

  defp format_incoming_dependencies(dependencies) do
    dependencies
    |> Enum.map(fn dep ->
      source = dep.source_component
      "- **#{source.name}** (#{source.type}) - `#{source.module_name}`"
    end)
    |> Enum.join("\n")
  end

  defp format_child_components(%Ecto.Association.NotLoaded{}), do: "Not loaded"
  defp format_child_components([]), do: "_No child components_"

  defp format_child_components(children) do
    children
    |> Enum.map(fn child ->
      description = if child.description, do: " - #{child.description}", else: ""
      "- **#{child.name}** (#{child.type}) - `#{child.module_name}`#{description}"
    end)
    |> Enum.join("\n")
  end

  defp format_stories(%Ecto.Association.NotLoaded{}), do: "Not loaded"
  defp format_stories([]), do: "_No related stories_"

  defp format_stories(stories) do
    stories
    |> Enum.map(fn story ->
      criteria =
        if story.acceptance_criteria && length(story.acceptance_criteria) > 0 do
          "\n  " <>
            (story.acceptance_criteria
             |> Enum.map(&"- #{&1}")
             |> Enum.join("\n  "))
        else
          ""
        end

      description = if story.description, do: ": #{story.description}", else: ""

      "- **#{story.title}**#{description}#{criteria}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_dependency_tree(component) do
    case component.outgoing_dependencies do
      %Ecto.Association.NotLoaded{} ->
        "_Dependency tree not loaded_"

      [] ->
        "_No dependencies - this is a leaf component_"

      deps ->
        """
        This component's dependency tree (showing direct dependencies):

        ```
        #{component.name} (#{component.type})
        #{format_tree_dependencies(deps)}
        ```

        Use this tree to understand the component's position in the architecture.
        Dependencies should flow from surface (controllers, liveviews) to domain (contexts, schemas).
        """
    end
  end

  defp format_tree_dependencies([]), do: ""

  defp format_tree_dependencies(deps) do
    deps
    |> Enum.with_index()
    |> Enum.map(fn {dep, index} ->
      target = dep.target_component
      is_last = index == length(deps) - 1
      branch = if is_last, do: "└─", else: "├─"

      "#{branch} #{target.name} (#{target.type})"
    end)
    |> Enum.join("\n")
  end
end
