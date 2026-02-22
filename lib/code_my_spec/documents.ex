defmodule CodeMySpec.Documents do
  @moduledoc """
  Context for managing document creation from markdown content.
  """

  alias CodeMySpec.Documents.MarkdownParser

  @app_prefixes ["CodeMySpec.", "CodeMySpecCli.", "CodeMySpecWeb."]

  @doc """
  Validates a spec file's H1 title matches its expected module name based on file path.

  Returns `:ok` or `{:error, reason}`.
  """
  @spec validate_h1_matches_path(String.t(), String.t()) :: :ok | {:error, String.t()}
  def validate_h1_matches_path(content, path) do
    expected_module = module_name_from_path(path)
    actual_module = extract_h1_module(content)

    cond do
      actual_module == nil ->
        {:error, "Missing H1 title. Expected: # #{expected_module}"}

      actual_module != expected_module ->
        {:error,
         "H1 title '#{actual_module}' does not match expected '#{expected_module}' based on file path"}

      true ->
        :ok
    end
  end

  @doc """
  Validates that internal dependencies (CodeMySpec.*, etc.) have corresponding files.

  Returns `{:ok, warnings}` where warnings is a list of dependency issues found.
  This is intentionally not a hard error to allow for gradual adoption.
  """
  @spec validate_internal_dependencies(String.t(), String.t()) :: {:ok, [String.t()]}
  def validate_internal_dependencies(content, base_dir) do
    dependencies = extract_dependencies(content)

    warnings =
      dependencies
      |> Enum.filter(&internal_module?/1)
      |> Enum.reject(&dependency_exists?(&1, base_dir))
      |> Enum.map(&"Dependency '#{&1}' not found (no spec or impl file)")

    {:ok, warnings}
  end

  defp internal_module?(module_name) do
    Enum.any?(@app_prefixes, &String.starts_with?(module_name, &1))
  end

  defp dependency_exists?(module_name, base_dir) do
    spec_path = module_to_spec_path(module_name, base_dir)
    impl_path = module_to_impl_path(module_name, base_dir)

    File.exists?(spec_path) or File.exists?(impl_path)
  end

  defp module_to_spec_path(module_name, base_dir) do
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join([base_dir, CodeMySpec.Paths.spec_dir() | path_parts]) <> ".spec.md"
  end

  defp module_to_impl_path(module_name, base_dir) do
    path_parts =
      module_name
      |> String.split(".")
      |> Enum.map(&Macro.underscore/1)

    Path.join([base_dir, "lib" | path_parts]) <> ".ex"
  end

  defp module_name_from_path(path) do
    path
    |> String.replace(~r{^.*/#{Regex.escape(CodeMySpec.Paths.spec_dir())}/}, "")
    |> String.replace_suffix(".spec.md", "")
    |> String.split("/")
    |> Enum.map_join(".", fn part ->
      part |> String.split("_") |> Enum.map_join(&String.capitalize/1)
    end)
  end

  defp extract_h1_module(content) do
    case Regex.run(~r/^# ([A-Z][a-zA-Z0-9_.]+)$/m, content) do
      [_, module] -> module
      _ -> nil
    end
  end

  defp extract_dependencies(content) do
    content
    |> String.split("\n")
    |> Enum.drop_while(&(not String.match?(&1, ~r/^## Dependencies/)))
    |> Enum.drop(1)
    |> Enum.take_while(&(not String.match?(&1, ~r/^##/)))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "- "))
    |> Enum.map(fn line ->
      line
      |> String.replace_prefix("- ", "")
      |> String.trim()
      |> String.split(" ")
      |> List.first()
    end)
    |> Enum.reject(&(&1 == "" or &1 == "None"))
  end

  @doc """
  Creates a document by validating sections against document type definition.

  ## Parameters
  - `markdown_content` - The markdown string to parse
  - `document_type` - Document type string (e.g., "spec", "schema", "context_spec") to look up definition

  Returns `{:ok, document}` with sections map and type or `{:error, reason}` on failure.
  """
  def create_dynamic_document(markdown_content, document_type) do
    with :ok <- validate_document_type(document_type),
         doc_def = CodeMySpec.Documents.Registry.get_definition(document_type),
         :ok <- validate_h1_title(markdown_content, document_type),
         {:ok, sections} <- MarkdownParser.parse(markdown_content),
         :ok <- validate_required_sections(sections, doc_def.required_sections),
         :ok <-
           validate_additional_sections(
             sections,
             doc_def.required_sections,
             doc_def.optional_sections,
             doc_def.allowed_additional_sections
           ) do
      {:ok, %{sections: sections, type: document_type}}
    end
  end

  defp validate_document_type(type) when is_binary(type) and byte_size(type) > 0, do: :ok
  defp validate_document_type(nil), do: {:error, "Document type is required"}
  defp validate_document_type(""), do: {:error, "Document type is required"}
  defp validate_document_type(_), do: {:error, "Document type must be a string"}

  # Spec files (spec, schema, context_spec) must have a valid H1 title
  @spec_types ["spec", "schema", "context_spec"]

  defp validate_h1_title(markdown_content, document_type) when document_type in @spec_types do
    case Regex.run(~r/^# ([A-Z][a-zA-Z0-9_.]+)$/m, markdown_content) do
      [_, _module_name] ->
        :ok

      _ ->
        {:error,
         "Missing or invalid H1 title. Spec files must start with '# ModuleName' in PascalCase format (e.g., # CodeMySpec.Accounts)"}
    end
  end

  defp validate_h1_title(_markdown_content, _document_type), do: :ok

  defp validate_required_sections(sections, required_sections) do
    missing =
      required_sections
      |> Enum.reject(fn
        # String: must be present
        section when is_binary(section) ->
          Map.has_key?(sections, section)

        # List: at least one must be present (OR logic)
        alternatives when is_list(alternatives) ->
          Enum.any?(alternatives, fn alt -> Map.has_key?(sections, alt) end)
      end)
      |> Enum.map(fn
        section when is_binary(section) -> section
        alternatives when is_list(alternatives) -> Enum.join(alternatives, " OR ")
      end)

    if Enum.empty?(missing) do
      :ok
    else
      {:error, "Missing required sections: #{Enum.join(missing, ", ")}"}
    end
  end

  # Metadata sections allowed in any document type
  @metadata_sections ["type"]

  defp validate_additional_sections(_sections, _required, _optional, "*"), do: :ok

  defp validate_additional_sections(
         sections,
         required_sections,
         optional_sections,
         allowed_additional
       ) do
    # Flatten OR alternatives in required_sections
    flattened_required =
      required_sections
      |> Enum.flat_map(fn
        section when is_binary(section) -> [section]
        alternatives when is_list(alternatives) -> alternatives
      end)

    allowed_sections =
      MapSet.new(
        flattened_required ++ optional_sections ++ allowed_additional ++ @metadata_sections
      )

    actual_sections = MapSet.new(Map.keys(sections))
    disallowed = MapSet.difference(actual_sections, allowed_sections)

    if MapSet.size(disallowed) == 0 do
      :ok
    else
      disallowed_list = MapSet.to_list(disallowed) |> Enum.sort()
      {:error, "Disallowed sections found: #{Enum.join(disallowed_list, ", ")}"}
    end
  end
end
