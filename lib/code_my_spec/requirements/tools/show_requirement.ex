defmodule CodeMySpec.Requirements.Tools.ShowRequirement do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Stories

  alias CodeMySpec.Requirements.Tools.Responses, as: RequirementsMapper
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Requirements.RequirementsFormatter

  @impl true
  def name, do: "show_requirement"

  @impl true
  def description do
    """
    Show a single requirement by name with full details including satisfaction
    status, task module, and entity context.
    """
  end

  @impl true
  def params do
    %{
      name:
        {:required,
         {:meta, :string,
          [description: "The requirement name (e.g. 'spec_written', 'tests_written')"]}},
      story_number:
        {:meta, :integer,
         [
           description:
             "A story's number — the same as entity_type `story` with entity_id set to it"
         ]},
      entity_id:
        {:meta, :string,
         [
           description: "The entity to scope the lookup to: a story's number, or a component's id"
         ]},
      entity_type:
        {:meta, :string, [description: "Entity type filter: 'component', 'story', or 'project'"]}
    }
  end

  @impl true
  def call(%{name: name} = params, context) do
    case CodeMySpec.Tools.project_scope(context) do
      {:ok, scope} ->
        respond_with_matches(scope, name, params, context)

      {:error, reason} ->
        RequirementsMapper.error(reason)
    end
  end

  defp respond_with_matches(scope, name, params, _context) do
    {{nodes, _edges}, _computed_at} = RequirementGraph.cached_graph(at_story_copy(scope, params))

    matches =
      nodes
      |> Enum.filter(&(&1.name == name))
      |> then(&CodeMySpec.Requirements.Directives.number_nodes(scope, &1))
      |> maybe_filter_entity(params)

    case matches do
      [] -> RequirementsMapper.error("Requirement '#{name}' not found")
      [single] -> detail_response(single)
      multiple -> list_response(name, multiple)
    end
  end

  # A named story's verdicts live at its assigned copy, independently of
  # epic membership and the checkout from which the caller asks.
  defp at_story_copy(scope, %{entity_type: "story", entity_id: number})
       when not is_nil(number) do
    case Stories.fetch_story_by_number(scope, number) do
      {:ok, %{working_copy_id: copy_id}} when is_binary(copy_id) ->
        %{scope | active_working_copy_id: copy_id}

      _ ->
        scope
    end
  end

  defp at_story_copy(scope, _params), do: scope

  defp maybe_filter_entity(nodes, %{entity_type: type, entity_id: id}) do
    Enum.filter(nodes, fn n ->
      n.entity_type == type and to_string(CodeMySpec.Requirements.Directives.entity_ref(n)) == id
    end)
  end

  defp maybe_filter_entity(nodes, _), do: nodes

  defp detail_response(node) do
    text = """
    # #{node.name}

    #{node.description || "No description"}

    **Status:** #{if node.satisfied, do: "Satisfied", else: "Not satisfied"}#{reason_line(node)}
    **Entity:** #{String.capitalize(node.entity_type)}: #{node.entity_name}
    **Execution:** #{execution_label(node.execution_type)}
    **Validation:** #{validation_label(node.validation_type)}
    """

    {:ok, String.trim(text)}
  end

  # The checkers already compute this — `three_amigos_complete`'s own
  # delegate names the seal specifically as its blocker when every other
  # condition is met — but nothing on this surface read it, so an agent
  # blocked by it had no way to tell "the seal" from "you haven't done the
  # work" short of a database read (f56b1787).
  defp reason_line(%{satisfied: true}), do: ""
  defp reason_line(%{satisfied: false, details: details}) when map_size(details) == 0, do: ""

  defp reason_line(%{satisfied: false, details: details}),
    do: "\n**Why:** #{RequirementsFormatter.format_details(details)}"

  defp list_response(name, nodes) do
    lines =
      Enum.map_join(nodes, "\n", fn n ->
        status = if n.satisfied, do: "[x]", else: "[ ]"
        "- #{status} #{String.capitalize(n.entity_type)}: #{n.entity_name}"
      end)

    text = "# #{name} (#{length(nodes)} instances)\n\n#{lines}"

    {:ok, String.trim(text)}
  end

  defp execution_label(:sub_agent), do: "Delegate to a sub-agent"
  defp execution_label(_), do: "You are the agent responsible"

  defp validation_label(:manual), do: "Manual — use `evaluate_task` when done"
  defp validation_label(:automatic), do: "Automatic — the stop hook will evaluate"
  defp validation_label(_), do: "Unknown"
end
