defmodule CodeMySpec.Documents do
  @moduledoc """
  Context for managing document creation from markdown content.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.Environments,
      CodeMySpec.Paths
    ],
    exports: :all

  alias CodeMySpec.Documents.MarkdownParser

  @doc """
  Creates a document by validating sections against document type definition.

  ## Parameters
  - `markdown_content` - The markdown string to parse
  - `document_type` - Document type string (e.g., "qa_story_brief", "architecture_proposal") to look up definition

  Returns `{:ok, document}` with sections map and type or `{:error, reason}` on failure.
  """
  def create_dynamic_document(markdown_content, document_type, opts \\ []) do
    strict? = Keyword.get(opts, :strict, true)

    # Normalize CRLF → LF. Specs written/edited on Windows carry `\r\n`, and
    # the `$`-anchored H1 and section extractors otherwise fail to match
    # because the `\r` sits between the value and the line end — so a
    # perfectly valid spec is rejected ("Missing or invalid H1 title", wrong
    # section set). Same class as the ComponentSync CRLF fix.
    markdown_content = String.replace(markdown_content, "\r\n", "\n")

    with :ok <- validate_document_type(document_type),
         doc_def = CodeMySpec.Documents.Registry.get_definition(document_type),
         {required, optional} = effective_section_requirements(doc_def, strict?),
         :ok <- validate_h1_title(markdown_content, document_type),
         {:ok, sections} <- MarkdownParser.parse(markdown_content),
         :ok <- validate_required_sections(sections, required),
         :ok <- validate_section_bodies(sections, required),
         :ok <-
           validate_additional_sections(
             sections,
             required,
             optional,
             doc_def.allowed_additional_sections
           ),
         :ok <- validate_parsed_issues(sections) do
      {:ok, %{sections: sections, type: document_type}}
    end
  end

  # In lenient mode (`strict: false`), required
  # sections are treated as optional so a spec file can be edited
  # piecewise without being forced to fill in every section. Structural
  # checks that don't depend on completeness (H1, parse, disallowed
  # sections, parsed-issue shape) still run.
  defp effective_section_requirements(doc_def, true),
    do: {doc_def.required_sections, doc_def.optional_sections}

  defp effective_section_requirements(doc_def, false) do
    flattened =
      doc_def.required_sections
      |> Enum.flat_map(fn
        section when is_binary(section) -> [section]
        alternatives when is_list(alternatives) -> alternatives
      end)

    {[], doc_def.optional_sections ++ flattened}
  end

  defp validate_document_type(type) when is_binary(type) and byte_size(type) > 0, do: :ok
  defp validate_document_type(nil), do: {:error, "Document type is required"}
  defp validate_document_type(""), do: {:error, "Document type is required"}
  defp validate_document_type(_), do: {:error, "Document type must be a string"}

  # Skill documents must have a valid H1 title
  @h1_types ["skill"]

  defp validate_h1_title(markdown_content, document_type) when document_type in @h1_types do
    case Regex.run(~r/^# ([A-Z][a-zA-Z0-9_.]+)$/m, markdown_content) do
      [_, _module_name] ->
        :ok

      _ ->
        {:error,
         "Missing or invalid H1 title. The document must start with '# ModuleName' in PascalCase format (e.g., # CodeMySpec.Accounts)"}
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

  defp validate_section_bodies(sections, required_sections) do
    empty =
      required_sections
      |> Enum.reject(fn
        section when is_binary(section) ->
          not section_empty?(Map.get(sections, section))

        alternatives when is_list(alternatives) ->
          Enum.any?(alternatives, fn alt ->
            Map.has_key?(sections, alt) and not section_empty?(Map.get(sections, alt))
          end)
      end)
      |> Enum.map(fn
        section when is_binary(section) -> section
        alternatives when is_list(alternatives) -> Enum.join(alternatives, " OR ")
      end)

    if Enum.empty?(empty) do
      :ok
    else
      {:error, "Empty required sections: #{Enum.join(empty, ", ")}"}
    end
  end

  # Only plain-text sections (no custom parser) can be detected as empty
  # at this layer. Sections with parsers (e.g. components, functions) may
  # legitimately return `[]` when the header is present but no H3 entries
  # are defined — that's a structural emptiness the parser owns, not a
  # missing-body concern.
  defp section_empty?(nil), do: true
  defp section_empty?(value) when is_binary(value), do: String.trim(value) == ""
  defp section_empty?(_), do: false

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

  @valid_severities ~w(critical high medium low info)

  # Same reasoning as `QaIssue.@scopes`, and the same drift: this list and that
  # one both restated `Issue`'s scopes and both missed `:framework` when it was
  # added in `9198be0f`. Read off the schema so the next scope needs adding
  # once.
  @valid_scopes CodeMySpec.Issues.Issue
                |> Ecto.Enum.values(:scope)
                |> Enum.map(&Atom.to_string/1)

  defp validate_parsed_issues(%{"issues" => issues}) when is_list(issues) do
    bad =
      Enum.filter(issues, fn
        %{severity: s, scope: sc} -> s not in @valid_severities or sc not in @valid_scopes
        %{severity: s} -> s not in @valid_severities
        _ -> true
      end)

    if bad == [] do
      :ok
    else
      titles = Enum.map_join(bad, ", ", &Map.get(&1, :title, "unknown"))

      {:error,
       "Issues section has entries with missing/invalid severity or scope. " <>
         "Each issue needs an `#### Severity` subsection with one of: " <>
         "CRITICAL, HIGH, MEDIUM, LOW, INFO. " <>
         "Optional `#### Scope` must be one of: app, qa, docs. Bad entries: #{titles}"}
    end
  end

  defp validate_parsed_issues(_sections), do: :ok
end
