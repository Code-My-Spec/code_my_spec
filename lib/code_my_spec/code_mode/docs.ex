defmodule CodeMySpec.CodeMode.Docs do
  @moduledoc """
  What a tool takes, rendered on demand.

  Progressive disclosure is the whole point. The index is one line per tool, so
  it costs a fraction of the 111 full schemas an agent is handed today; the
  full page for one tool is fetched only when that tool is about to be called.
  An agent that does not know the name searches for it.

  Written from the JSON Schema the tool already publishes, so a tool whose
  arguments change never has documentation that disagrees with it. Nothing here
  is hand-maintained, which is the only version of this that stays true.
  """

  alias CodeMySpec.CodeMode.Catalog

  @doc "The index, one tool, or search results — see `CodeMode.docs/2`."
  @spec render(Catalog.t(), keyword()) :: String.t()
  def render(catalog, opts \\ []) do
    case {Keyword.get(opts, :name), Keyword.get(opts, :search)} do
      {nil, nil} -> index(catalog)
      {name, _search} when is_binary(name) -> page(catalog, name)
      {_name, term} when is_binary(term) -> search(catalog, term)
    end
  end

  defp index(catalog) do
    body =
      catalog
      |> Catalog.names()
      |> Enum.map_join("\n", fn name -> "  #{name} — #{summary(catalog[name])}" end)

    """
    #{map_size(catalog)} tools are callable from a script. Call them directly by
    name, passing one table: `local s = get_story({ story_id = "970" })`.

    A tool that cannot answer returns nil and an error table:
    `local s, err = get_story({ story_id = "nope" })`

    Ask for one by name to see its arguments.

    #{body}

    Not callable from a script — call these directly, as tools:
    #{Enum.map_join(Catalog.excluded(), ", ", & &1)}
    """
  end

  defp page(catalog, name) do
    case Catalog.fetch(catalog, name) do
      {:ok, tool} -> full(tool)
      :error -> not_found(catalog, name)
    end
  end

  defp full(tool) do
    """
    # #{tool.name}

    #{String.trim(tool.description)}

    ## Arguments

    #{arguments(tool.schema)}

    ## Example

    ```lua
    local result, err = #{tool.name}(#{example(tool.schema)})
    if result == nil then return "failed: " .. err.message end
    return result
    ```
    """
  end

  defp arguments(%{"properties" => properties} = schema) when map_size(properties) > 0 do
    required = Map.get(schema, "required", [])

    properties
    |> Enum.sort_by(fn {name, _spec} -> {name not in required, name} end)
    |> Enum.map_join("\n", fn {name, spec} ->
      "  #{name} (#{Map.get(spec, "type", "any")}#{requirement(name, required)})#{described(spec)}"
    end)
  end

  defp arguments(_schema), do: "  none"

  defp requirement(name, required) do
    if name in required, do: ", required", else: ""
  end

  defp described(%{"description" => description}) when is_binary(description),
    do: " — " <> String.trim(description)

  defp described(_spec), do: ""

  # Built from the required arguments only: an example carrying every optional
  # is a worse starting point than one that shows the minimum call.
  defp example(%{"properties" => properties} = schema) do
    case Map.get(schema, "required", []) do
      [] -> "{}"
      required -> "{ " <> Enum.map_join(required, ", ", &pair(&1, properties)) <> " }"
    end
  end

  defp example(_schema), do: "{}"

  defp pair(name, properties) do
    "#{name} = #{placeholder(Map.get(properties, name, %{}))}"
  end

  defp placeholder(%{"type" => "integer"}), do: "1"
  defp placeholder(%{"type" => "number"}), do: "1"
  defp placeholder(%{"type" => "boolean"}), do: "true"
  defp placeholder(%{"type" => "array"}), do: "{}"
  defp placeholder(%{"type" => "object"}), do: "{}"
  defp placeholder(_spec), do: ~s("…")

  defp search(catalog, term) do
    needle = String.downcase(term)

    matches =
      catalog
      |> Enum.filter(fn {name, tool} -> matches?(name, tool, needle) end)
      |> Enum.sort_by(fn {name, _tool} -> {not String.contains?(name, needle), name} end)

    render_matches(matches, catalog, term)
  end

  defp matches?(name, tool, needle) do
    String.contains?(name, needle) or String.contains?(String.downcase(tool.description), needle)
  end

  defp render_matches([], catalog, term) do
    "Nothing matches #{inspect(term)}. #{map_size(catalog)} tools are available; " <>
      "ask for the index to see them."
  end

  defp render_matches(matches, _catalog, term) do
    body =
      Enum.map_join(matches, "\n", fn {name, tool} -> "  #{name} — #{summary(tool)}" end)

    "#{length(matches)} tools match #{inspect(term)}. Ask for one by name to see its arguments.\n\n#{body}"
  end

  # A name that is close but not exact is the common miss, so say the near ones
  # rather than only that it was not found.
  defp not_found(catalog, name) do
    near =
      catalog
      |> Catalog.names()
      |> Enum.filter(&String.contains?(&1, first_word(name)))
      |> Enum.take(5)

    case near do
      [] -> "No tool called #{inspect(name)}. Ask for the index to see what there is."
      names -> "No tool called #{inspect(name)}. Did you mean: #{Enum.join(names, ", ")}?"
    end
  end

  defp first_word(name), do: name |> String.split("_") |> List.first()

  defp summary(tool) do
    tool.description
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.trim()
  end
end
