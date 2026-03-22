defmodule CodeMySpec.McpServers.Components.ComponentsMapper do
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Formatters

  def component_response(component) do
    similar_components =
      case Map.get(component, :similar_components, :not_loaded) do
        %Ecto.Association.NotLoaded{} -> []
        similar when is_list(similar) -> Enum.map(similar, &component_summary/1)
        _ -> []
      end

    Response.tool()
    |> Response.json(%{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description,
      similar_components: similar_components
    })
  end

  def validation_error(changeset) do
    Response.tool()
    |> Response.error(Formatters.format_changeset_errors(changeset))
  end

  def error(error) when is_atom(error), do: error |> to_string() |> error()

  def error(error) when is_binary(error) do
    Response.tool()
    |> Response.error(error)
  end

  def components_list_response(components) do
    Response.tool()
    |> Response.json(%{
      components: Enum.map(components, &component_summary/1)
    })
  end

  def not_found_error do
    Response.tool()
    |> Response.error("Resource not found")
  end

  def components_batch_response(components) do
    Response.tool()
    |> Response.json(%{
      success: true,
      count: length(components),
      components: Enum.map(components, &component_summary/1)
    })
  end

  def dependencies_batch_response(dependencies) do
    Response.tool()
    |> Response.json(%{
      success: true,
      count: length(dependencies),
      dependencies: Enum.map(dependencies, &dependency_summary/1)
    })
  end

  def batch_errors_response(successes, failures) do
    Response.tool()
    |> Response.json(%{
      success: false,
      created_count: length(successes),
      failed_count: length(failures),
      created_components: Enum.map(successes, &component_summary/1),
      errors:
        Enum.map(failures, fn {index, changeset} ->
          %{
            index: index,
            errors: Formatters.format_changeset_errors(changeset)
          }
        end)
    })
  end

  def prompt_response(prompt) do
    Response.tool()
    |> Response.text(prompt)
  end

  defp component_summary(component) do
    %{
      id: component.id,
      name: component.name,
      type: component.type,
      module_name: component.module_name,
      description: component.description
    }
  end

  defp dependency_summary(dependency) do
    %{
      id: dependency.id,
      source_component: component_summary(dependency.source_component),
      target_component: component_summary(dependency.target_component)
    }
  end
end
