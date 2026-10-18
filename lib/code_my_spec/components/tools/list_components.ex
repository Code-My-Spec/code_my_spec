defmodule CodeMySpec.Components.Tools.ListComponents do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Components
  alias CodeMySpec.Components.Tools.Responses, as: ComponentsMapper

  @impl true
  def name, do: "list_components"

  @impl true
  def description do
    "Lists all components in a project"
  end

  @impl true
  def params do
    %{}
  end

  @impl true
  def call(_params, context) do
    case components(context) do
      {:ok, components} -> ComponentsMapper.components_list_response(components)
      {:error, atom} -> ComponentsMapper.error(atom)
    end
  end

  @impl true
  def script_result(_params, context) do
    with {:ok, components} <- components(context) do
      {:ok, Enum.map(components, &row/1)}
    end
  end

  defp components(context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context) do
      {:ok, Components.list_components(scope)}
    end
  end

  defp row(c) do
    %{
      "id" => c.id,
      "name" => c.name,
      "type" => c.type,
      "module_name" => c.module_name,
      "description" => c.description,
      "provenance" => c.provenance && to_string(c.provenance)
    }
  end
end
