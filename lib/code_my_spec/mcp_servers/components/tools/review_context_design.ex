defmodule CodeMySpec.McpServers.Components.Tools.ReviewContextDesign do
  @moduledoc "Reviews current context design against best practices and provides architectural feedback"

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.Stories
  alias CodeMySpec.Components
  alias CodeMySpec.McpServers.Components.{ComponentsMapper, Tools.ShowArchitecture}
  alias CodeMySpec.McpServers.Validators

  schema do
  end

  @impl true
  def execute(_params, frame) do
    case Validators.validate_scope(frame) do
      {:ok, scope} ->
        build_review_prompt(scope, frame)

      {:error, atom} ->
        {:reply, ComponentsMapper.error(atom), frame}
    end
  end

  defp build_review_prompt(scope, frame) do
    unsatisfied_stories = Stories.list_unsatisfied_stories(scope)
    {:reply, architecture_response, _} = ShowArchitecture.execute(%{}, frame)
    dependency_validation = Components.validate_dependency_graph(scope)

    prompt = """
    ## Context Design Review

    **Current Architecture:**
    #{format_architecture_from_response(architecture_response)}

    **Unsatisfied Stories:** #{length(unsatisfied_stories)} stories without assigned components
    #{format_unsatisfied_stories(unsatisfied_stories)}

    **Dependency Analysis:**
    #{format_dependency_analysis(dependency_validation)}

    **Review Questions:**
    1. Are the context boundaries aligned with business capabilities?
    2. Do any contexts have unclear or overlapping responsibilities?
    3. Are there missing contexts needed to satisfy the user stories?
    4. Are dependencies properly justified and non-circular?
    5. Should any contexts be split or merged based on cohesion?

    **Next Steps:**
    Focus on:
    - Assigning contexts to the #{length(unsatisfied_stories)} unsatisfied stories
    - Reviewing dependency issues if any were found
    - Ensuring each context has clear ownership boundaries
    """

    {:reply, ComponentsMapper.prompt_response(prompt), frame}
  end

  defp format_unsatisfied_stories([]) do
    "All stories have been assigned to components ✅"
  end

  defp format_unsatisfied_stories(stories) do
    stories
    |> Enum.take(5)
    |> Enum.map_join("\n", fn story ->
      "- **#{story.title}**: #{String.slice(story.description || "", 0, 100)}..."
    end)
    |> then(fn formatted ->
      if length(stories) > 5 do
        "#{formatted}\n- ... and #{length(stories) - 5} more"
      else
        formatted
      end
    end)
  end

  defp format_dependency_analysis(:ok), do: "No circular dependencies found ✅"

  defp format_dependency_analysis({:error, cycles}),
    do: "#{length(cycles)} circular dependencies detected ❌"

  defp format_architecture_from_response(response) do
    case response.content do
      [%{"text" => json_text}] ->
        case Jason.decode(json_text) do
          {:ok, architecture_data} -> format_architecture_json(architecture_data)
          {:error, _} -> "Unable to parse architecture data"
        end

      _ ->
        "Unable to retrieve architecture data"
    end
  end

  defp format_architecture_json(%{"architecture" => arch}) do
    components = arch["components"]

    # Get entry points (components with stories at depth 0)
    entry_points =
      components
      |> Enum.filter(fn comp ->
        comp["depth"] == 0 and comp["component"]["metrics"]["has_stories"]
      end)
      |> Enum.uniq_by(& &1["component"]["id"])

    Enum.map_join(entry_points, "\n\n", &format_component_tree/1)
  end

  defp format_component_tree(%{"component" => comp}) do
    # Format the main component
    stories_text = format_component_stories(comp["stories"])
    deps_text = format_component_dependencies(comp["dependencies"])

    header = "**#{comp["name"]}** (#{comp["type"]}) - #{comp["description"]}"

    stories_section =
      if comp["stories"] == [] do
        "\n  No stories"
      else
        "\n  Stories:\n#{stories_text}"
      end

    deps_section =
      if comp["dependencies"] == [] do
        ""
      else
        "\n  Dependencies:\n#{deps_text}"
      end

    "#{header}#{stories_section}#{deps_section}"
  end

  defp format_component_stories(stories) do
    Enum.map_join(stories, "\n", fn story ->
      criteria =
        if story["acceptance_criteria"] == [] do
          ""
        else
          criteria_list = Enum.map(story["acceptance_criteria"], &"      - #{&1}")
          "\n    Acceptance Criteria:\n#{Enum.join(criteria_list, "\n")}"
        end

      "    - **#{story["title"]}**: #{story["description"]}#{criteria}"
    end)
  end

  defp format_component_dependencies(dependencies) do
    Enum.map_join(dependencies, "\n", fn dep ->
      "    - #{dep["target"]["name"]} (#{dep["target"]["type"]})"
    end)
  end
end
