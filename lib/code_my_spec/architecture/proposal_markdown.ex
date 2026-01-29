defmodule CodeMySpec.Architecture.ProposalMarkdown do
  @moduledoc """
  Serialize and deserialize architecture proposals to/from markdown format.

  Uses Earmark for proper markdown parsing instead of regex.
  """

  alias CodeMySpec.Architecture.Proposal

  @proposal_dir "docs/architecture/proposals"

  def proposal_dir, do: @proposal_dir

  def proposal_path(app_name) do
    slug = app_name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    Path.join(@proposal_dir, "#{slug}.proposal.md")
  end

  @doc """
  Serializes a Proposal struct to markdown format.
  """
  def to_markdown(%Proposal{} = proposal) do
    """
    # Architecture Proposal: #{proposal.app_name}

    #{format_contexts(proposal.contexts)}

    #{format_surface_components(proposal.surface_components)}

    #{format_dependencies(proposal.dependencies)}
    """
    |> String.trim()
  end

  @doc """
  Parses markdown content into a Proposal struct using Earmark.
  """
  def from_markdown(content) do
    case Earmark.Parser.as_ast(content) do
      {:ok, ast, _} ->
        parse_ast(ast)

      {:error, _, errors} ->
        {:error, "Failed to parse markdown: #{inspect(errors)}"}
    end
  end

  # AST Parsing

  defp parse_ast(ast) do
    with {:ok, app_name} <- extract_app_name(ast),
         {:ok, sections} <- extract_h2_sections(ast) do
      contexts = parse_contexts_section(sections["contexts"] || [])
      surface = parse_surface_section(sections["surface components"] || [])
      deps = parse_dependencies_section(sections["dependencies"] || [])

      {:ok,
       Proposal.new(%{
         app_name: app_name,
         contexts: contexts,
         surface_components: surface,
         dependencies: deps
       })}
    end
  end

  defp extract_app_name(ast) do
    case Enum.find(ast, &match?({"h1", _, _, _}, &1)) do
      {"h1", _, content, _} ->
        text = extract_text(content)

        case Regex.run(~r/Architecture Proposal:\s*(.+)/, text) do
          [_, name] -> {:ok, String.trim(name)}
          _ -> {:error, "H1 must be 'Architecture Proposal: AppName'"}
        end

      nil ->
        {:error, "Missing H1 title"}
    end
  end

  defp extract_h2_sections(ast) do
    {sections, current} =
      Enum.reduce(ast, {%{}, nil}, fn
        {"h2", _, content, _}, {sections, current} ->
          key = extract_text(content) |> String.downcase()
          updated = if current, do: finalize_section(sections, current), else: sections
          {updated, {key, []}}

        _element, {sections, nil} ->
          {sections, nil}

        element, {sections, {key, content}} ->
          {sections, {key, [element | content]}}
      end)

    final = if current, do: finalize_section(sections, current), else: sections
    {:ok, final}
  end

  defp finalize_section(sections, {key, content}) do
    Map.put(sections, key, Enum.reverse(content))
  end

  # Parse Contexts section (H3 entries)

  defp parse_contexts_section(ast) do
    ast
    |> split_by_h3()
    |> Enum.map(&parse_single_context/1)
  end

  defp parse_single_context({name, content}) do
    fields = extract_fields(content)
    children = extract_children(content)

    %{
      name: name,
      description: fields["description"],
      story_ids: parse_story_ids(fields["stories"]),
      children: children
    }
  end

  # Parse Surface Components section (H3 entries)

  defp parse_surface_section(ast) do
    ast
    |> split_by_h3()
    |> Enum.map(&parse_single_surface/1)
  end

  defp parse_single_surface({name, content}) do
    fields = extract_fields(content)

    %{
      name: name,
      type: fields["type"] || "live_view",
      description: fields["description"],
      story_ids: parse_story_ids(fields["stories"])
    }
  end

  # Parse Dependencies section (list items)

  defp parse_dependencies_section(ast) do
    ast
    |> Enum.flat_map(&extract_list_items/1)
    |> Enum.map(&parse_dependency_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_dependency_line(text) do
    case Regex.run(~r/(.+?)\s*->\s*(.+)/, text) do
      [_, from, to] -> %{from: String.trim(from), to: String.trim(to)}
      _ -> nil
    end
  end

  # Helper: split AST by H3 headings

  defp split_by_h3(ast) do
    {groups, current} =
      Enum.reduce(ast, {[], nil}, fn
        {"h3", _, content, _}, {groups, current} ->
          name = extract_text(content)
          updated = if current, do: [current | groups], else: groups
          {updated, {name, []}}

        _element, {groups, nil} ->
          {groups, nil}

        element, {groups, {name, content}} ->
          {groups, {name, [element | content]}}
      end)

    final = if current, do: [current | groups], else: groups

    final
    |> Enum.reverse()
    |> Enum.map(fn {name, content} -> {name, Enum.reverse(content)} end)
  end

  # Helper: extract key-value fields from list items

  defp extract_fields(ast) do
    ast
    |> Enum.flat_map(&extract_list_items/1)
    |> Enum.map(&parse_field_line/1)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  defp parse_field_line(text) do
    case Regex.run(~r/^\*\*(.+?):\*\*\s*(.*)$/, text) do
      [_, key, value] ->
        {String.downcase(key), String.trim(value)}

      _ ->
        nil
    end
  end

  # Helper: extract children from H4 section

  defp extract_children(ast) do
    # Find content after H4 "Children"
    {_, after_h4} =
      Enum.reduce(ast, {:before, []}, fn
        {"h4", _, content, _}, {:before, _} ->
          if extract_text(content) =~ ~r/children/i do
            {:after, []}
          else
            {:before, []}
          end

        element, {:after, acc} ->
          {:after, [element | acc]}

        _, acc ->
          acc
      end)

    after_h4
    |> Enum.reverse()
    |> Enum.flat_map(&extract_list_items/1)
    |> Enum.map(&parse_child_line/1)
    |> Enum.reject(&is_nil/1)
  end

  defp parse_child_line(text) do
    case Regex.run(~r/^([^\(]+)\s*\(([^\)]+)\)(?::\s*(.+))?$/, String.trim(text)) do
      [_, name, type, description] ->
        %{name: String.trim(name), type: type, description: description}

      [_, name, type] ->
        %{name: String.trim(name), type: type, description: nil}

      _ ->
        nil
    end
  end

  # Helper: extract list items as text

  defp extract_list_items({"ul", _, items, _}) do
    Enum.map(items, fn {"li", _, content, _} -> extract_text(content) end)
  end

  defp extract_list_items(_), do: []

  # Helper: extract text from AST nodes

  defp extract_text(nodes) when is_list(nodes) do
    nodes |> Enum.map(&extract_text/1) |> Enum.join("") |> String.trim()
  end

  defp extract_text(text) when is_binary(text), do: text
  defp extract_text({"strong", _, content, _}), do: "**#{extract_text(content)}**"
  defp extract_text({"em", _, content, _}), do: "_#{extract_text(content)}_"
  defp extract_text({"code", _, content, _}), do: "`#{extract_text(content)}`"
  defp extract_text({_tag, _, content, _}), do: extract_text(content)
  defp extract_text(_), do: ""

  defp parse_story_ids(nil), do: []
  defp parse_story_ids("_none_"), do: []

  defp parse_story_ids(text) do
    text
    |> String.split(~r/,\s*/)
    |> Enum.map(&String.trim/1)
    |> Enum.map(&Integer.parse/1)
    |> Enum.map(fn
      {int, _} -> int
      :error -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Formatting (output)

  defp format_contexts([]), do: "## Contexts\n\n_No contexts defined_"

  defp format_contexts(contexts) do
    formatted = contexts |> Enum.map(&format_context/1) |> Enum.join("\n\n")
    "## Contexts\n\n#{formatted}"
  end

  defp format_context(ctx) do
    children_section =
      if ctx.children && ctx.children != [] do
        children =
          ctx.children
          |> Enum.map(fn child ->
            desc = if child.description, do: ": #{child.description}", else: ""
            "- #{child.name} (#{child.type})#{desc}"
          end)
          |> Enum.join("\n")

        "\n\n#### Children\n\n#{children}"
      else
        ""
      end

    """
    ### #{ctx.name}

    - **Type:** context
    - **Description:** #{ctx.description || "_No description_"}
    - **Stories:** #{format_story_ids(ctx.story_ids)}#{children_section}
    """
    |> String.trim()
  end

  defp format_surface_components([]), do: "## Surface Components\n\n_No surface components defined_"

  defp format_surface_components(components) do
    formatted = components |> Enum.map(&format_surface_component/1) |> Enum.join("\n\n")
    "## Surface Components\n\n#{formatted}"
  end

  defp format_surface_component(comp) do
    """
    ### #{comp.name}

    - **Type:** #{comp.type}
    - **Description:** #{comp.description || "_No description_"}
    - **Stories:** #{format_story_ids(comp.story_ids)}
    """
    |> String.trim()
  end

  defp format_dependencies([]), do: "## Dependencies\n\n_No dependencies defined_"

  defp format_dependencies(dependencies) do
    formatted = dependencies |> Enum.map(fn d -> "- #{d.from} -> #{d.to}" end) |> Enum.join("\n")
    "## Dependencies\n\n#{formatted}"
  end

  defp format_story_ids(nil), do: "_none_"
  defp format_story_ids([]), do: "_none_"
  defp format_story_ids(ids), do: Enum.join(ids, ", ")
end
