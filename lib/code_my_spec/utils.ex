defmodule CodeMySpec.Utils do
  @moduledoc false

  alias CodeMySpec.Components.Component
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Utils.Paths

  # Delegate path-related functions to Paths module
  defdelegate resolve_context_path(path), to: Paths
  defdelegate module_to_path(module_name), to: Paths

  def component_files(
        %Component{module_name: module_name, type: type},
        %Project{}
      ) do
    module_path = Paths.module_to_path(module_name)

    base_files = %{
      design_file: "docs/design/#{module_path}.md",
      code_file: "lib/#{module_path}.ex",
      test_file: "test/#{module_path}_test.exs",
      spec_file: "docs/spec/#{module_path}.spec.md"
    }

    # Add review_file for context components (both :context and :coordination_context)
    if type in ["context", "coordination_context"] do
      Map.put(base_files, :review_file, "docs/spec/#{module_path}/design_review.md")
    else
      base_files
    end
  end

  def component_files(module_name) do
    module_path = Paths.module_to_path(module_name)

    %{
      design_file: "docs/design/#{module_path}.md",
      code_file: "lib/#{module_path}.ex",
      test_file: "test/#{module_path}_test.exs",
      spec_file: "docs/spec/#{module_path}.spec.md"
    }
  end

  def changeset_error_to_string(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", safe_to_string(key, value, opts))
      end)
    end)
    |> flatten_errors()
    |> Enum.map_join(", ", fn {field, message} -> "#{field}: #{message}" end)
  end

  defp safe_to_string(_key, value, _opts) do
    to_string(value)
  rescue
    Protocol.UndefinedError ->
      # Handle complex types that don't implement String.Chars (like Ecto.Enum metadata)
      # For enum types, extract the valid values if available
      case value do
        {:parameterized, {Ecto.Enum, %{mappings: mappings}}} when is_list(mappings) ->
          mappings
          |> Keyword.values()
          |> Enum.map_join(", ", &to_string/1)

        _ ->
          inspect(value)
      end
  end

  defp flatten_errors(errors, prefix \\ nil) do
    Enum.flat_map(errors, fn {field, value} ->
      field_name = if prefix, do: "#{prefix}.#{field}", else: field
      flatten_error_value(field_name, value)
    end)
  end

  defp flatten_error_value(field_name, value) when is_list(value) do
    if Enum.all?(value, &is_map/1) do
      value
      |> Enum.with_index()
      |> Enum.flat_map(fn {item_errors, index} ->
        flatten_errors(item_errors, "#{field_name}[#{index}]")
      end)
    else
      Enum.map(value, fn msg -> {field_name, msg} end)
    end
  end

  defp flatten_error_value(field_name, value) when is_map(value) do
    flatten_errors(value, field_name)
  end

  defp flatten_error_value(field_name, value) do
    [{field_name, value}]
  end
end
