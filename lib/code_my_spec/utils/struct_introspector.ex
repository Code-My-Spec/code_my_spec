defmodule CodeMySpec.Utils.StructIntrospector do
  @moduledoc """
  Provides introspection capabilities for Ecto schemas, extracting field
  specifications, requirements, and descriptions from schema definitions.
  """

  @doc """
  Introspects an Ecto schema module and returns detailed field specifications.

  ## Parameters
  - `schema_module` - The Ecto schema module to introspect

  ## Returns
  A map containing:
  - `:fields` - List of all field names
  - `:required_fields` - List of required field names
  - `:optional_fields` - List of optional field names
  - `:field_specs` - Map of field specifications with types and descriptions
  - `:defaults` - Map of default values for fields

  ## Examples

      iex> Code.ensure_loaded(CodeMySpec.ComponentDesignFixture)
      iex> CodeMySpec.Utils.StructIntrospector.introspect(CodeMySpec.ComponentDesignFixture)
      %{
        fields: [:purpose, :public_api, :execution_flow, :other_sections],
        required_fields: [:purpose, :public_api, :execution_flow],
        optional_fields: [:other_sections],
        field_specs: %{
          purpose: %{type: :string, description: "Component's purpose", required: true},
          public_api: %{type: :string, description: "Public API specification", required: true},
          execution_flow: %{type: :string, description: "No description available", required: true},
          other_sections: %{type: :map, description: "No description available", required: false}
        }
      }
  """
  def introspect(schema_module) when is_atom(schema_module) do
    is_schema = function_exported?(schema_module, :__schema__, 1)

    with true <- is_schema,
         fields <- get_fields(schema_module) do
      # Get field documentation/descriptions if available
      field_docs = get_field_docs(schema_module)

      # Get required fields from changeset validation
      required_fields = get_required_fields(schema_module)

      optional_fields = fields -- required_fields

      # Build comprehensive field specifications
      field_specs = build_field_specs(fields, schema_module, field_docs, required_fields)

      %{
        fields: fields,
        required_fields: required_fields,
        optional_fields: optional_fields,
        field_specs: field_specs
      }
    else
      false -> {:error, "#{schema_module} is not an Ecto schema module"}
    end
  end

  def introspect(schema_instance) when is_struct(schema_instance) do
    introspect(schema_instance.__struct__)
  end

  def introspect(_), do: {:error, "Input must be an Ecto schema module or schema instance"}

  # Get fields using convention-based approach
  defp get_fields(schema_module) do
    schema_module.__schema__(:fields)
  end

  # Get required fields using convention-based approach
  defp get_required_fields(schema_module) do
    schema_module.required_fields()
  end

  # Get field documentation using convention
  defp get_field_docs(schema_module) do
    if function_exported?(schema_module, :field_descriptions, 0) do
      schema_module.field_descriptions()
    else
      %{}
    end
  end

  # Get Ecto field type
  defp get_ecto_type(schema_module, field) do
    schema_module.__schema__(:type, field)
  rescue
    _ -> :any
  end

  # Build comprehensive field specifications
  defp build_field_specs(fields, schema_module, field_docs, required_fields) do
    fields
    |> Enum.reduce(%{}, fn field, acc ->
      spec = %{
        type: get_ecto_type(schema_module, field),
        description: Map.get(field_docs, field, "No description available"),
        required: field in required_fields
      }

      Map.put(acc, field, spec)
    end)
  end
end
