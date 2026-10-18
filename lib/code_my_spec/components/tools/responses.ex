defmodule CodeMySpec.Components.Tools.Responses do
  @moduledoc false

  # `provenance` says whether the component was authored as intended
  # architecture or discovered from code (3aeb66cf); `parent_component_id` is
  # the component it sits under, which authoring can now set.
  def component_response(component) do
    {:ok,
     JSON.encode!(%{
       id: component.id,
       name: component.name,
       type: component.type,
       module_name: component.module_name,
       description: component.description,
       parent_component_id: component.parent_component_id,
       provenance: component.provenance
     })}
  end

  @doc """
  The component, plus something the caller has to act on.

  Text rather than JSON, deliberately: a structured payload is read instead of
  the text beside it, not as well as, so a note attached to `Response.json/2`
  is a note nobody sees. The whole point of this clause is that the agent reads
  and acts on it.
  """
  def component_response(component, note) when is_binary(note) do
    {:ok,
     """
     Created `#{component.module_name}` (#{component.type}) — id `#{component.id}`.
     #{note}
     """}
  end

  def validation_error(changeset) do
    {:error, CodeMySpec.Tools.changeset_errors(changeset)}
  end

  def error(error) when is_atom(error), do: error |> to_string() |> error()

  def error(error) when is_binary(error) do
    {:error, error}
  end

  def components_list_response(components) do
    {:ok,
     JSON.encode!(%{
       components: Enum.map(components, &component_summary/1)
     })}
  end

  def not_found_error do
    {:error, "Resource not found"}
  end

  def dependencies_batch_response(dependencies) do
    {:ok,
     JSON.encode!(%{
       success: true,
       count: length(dependencies),
       dependencies: Enum.map(dependencies, &dependency_summary/1)
     })}
  end

  def prompt_response(prompt) do
    {:ok, prompt}
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
