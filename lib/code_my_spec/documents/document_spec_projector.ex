defmodule CodeMySpec.Documents.DocumentSpecProjector do
  @moduledoc """
  Projects document definitions from Documents.Registry into markdown specifications
  for AI-generated design documents.
  """

  alias CodeMySpec.Documents.Registry, as: DocumentRegistry

  @doc """
  Generates a markdown specification for a component type.
  """
  def project_spec(component_type) do
    definition = DocumentRegistry.get_definition(component_type)
    type_name = format_type_name(component_type)

    """
    # #{type_name}

    #{definition.overview}

    ## Required Sections

    #{format_sections(definition.required_sections, definition.section_descriptions)}

    ## Optional Sections

    #{format_optional_sections(definition.optional_sections, definition.section_descriptions)}
    """
  end

  defp format_type_name(component_type) do
    component_type
    |> String.split("_")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp format_sections(sections, descriptions) do
    sections
    |> List.flatten()
    |> Enum.map_join("\n\n", fn section ->
      description = Map.get(descriptions, section, "No description available")
      "### #{format_section_name(section)}\n\n#{description}"
    end)
  end

  defp format_optional_sections([], _descriptions) do
    "None"
  end

  defp format_optional_sections(sections, descriptions) do
    format_sections(sections, descriptions)
  end

  defp format_section_name(section) do
    section
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
