defmodule CodeMySpec.Requirements.Directives do
  @moduledoc """
  Requirements rendered as the directive text an agent reads: the next
  requirements, a story's execution wave, and how each node is named.

  The MCP tools wrap this in a response; the agent harness and the next-task
  page show it as it is.
  """

  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Stories

  def format_story_execution(execution, active_subagents \\ %{}) do
    execution = number_wave(execution)

    "#{story_header(execution.story)}\n\nStatus: #{execution.status}\n\n" <>
      execution_body(execution, active_subagents)
  end

  # A story node in the wave is the selected story's own.
  defp number_wave(%{story: %{number: number, id: id}, wave: wave} = execution) do
    %{execution | wave: Enum.map(wave, &number_node(&1, id, number))}
  end

  defp number_wave(execution), do: execution

  defp number_node(%{entity_type: "story", entity_id: id} = node, id, number),
    do: Map.put(node, :entity_number, number)

  defp number_node(node, _id, _number), do: node

  defp story_header(nil), do: "# Story scope"
  defp story_header(story), do: "# Story #{story.number}: #{story.title}"

  defp execution_body(%{status: :ready} = execution, active_subagents) do
    wave = execution.wave

    "Wave: #{length(wave)} requirement(s)\nRemaining: #{execution.remaining}\n\n" <>
      format_next_requirements(wave, active_subagents) <>
      "\n\nExecution metadata:\n" <> Enum.map_join(wave, "\n", &execution_metadata/1)
  end

  # `:complete` with no story is a copy that has nothing actionable, which is
  # not the same statement as a story finishing. A copy answered for the
  # project says so in the project's terms; "this story is complete" names a
  # story that was never selected.
  defp execution_body(%{status: :complete, story: nil, reason: reason}, _active), do: reason

  defp execution_body(%{status: :complete}, _active),
    do:
      "This story is complete for this working copy. Selecting the next story requires a new assignment."

  defp execution_body(execution, _active) do
    blockers = Enum.map_join(execution.blockers, "\n", &blocker_line/1)

    Enum.join(Enum.reject([execution.reason, blockers], &(&1 in [nil, ""])), "\n\n")
  end

  defp execution_metadata(node) do
    "- #{node.name} (#{node.entity_type} #{entity_ref(node)}): " <>
      "role=#{Map.get(node, :role) || "any"}, runs_in=#{Requirement.runs_in(node.execution_type)}, " <>
      "orchestrated_by=#{node.orchestrated_by || "none"}, " <>
      "validation_type=#{node.validation_type}"
  end

  defp blocker_line(blocker) do
    "- #{Map.get(blocker, :name, "prerequisite")}: #{Map.get(blocker, :entity_name, "")} " <>
      to_string(Map.get(blocker, :reason) || Map.get(blocker, :description) || "unsatisfied")
  end

  def format_next_requirements(nodes, active_subagents \\ %{}) do
    {orchestrated, standalone} = Enum.split_with(nodes, & &1.orchestrated_by)

    # Only show the first (highest-priority) orchestration group,
    # scoped to a specific parent entity (e.g., one context at a time).
    orchestrated_section =
      case orchestrated do
        [] ->
          ""

        [first | _] ->
          key = {first.orchestrated_by, first.parent_entity_id}

          group_nodes =
            Enum.filter(orchestrated, &({&1.orchestrated_by, &1.parent_entity_id} == key))

          orchestrator = first.orchestrated_by
          parent_name = first.parent_entity_name || "unknown"
          header = orchestration_prompt(orchestrator)
          inner = format_satisfied_by_groups(group_nodes, active_subagents)

          "## #{parent_name}\n\n#{header}\n\n#{inner}"
      end

    # When an orchestration group is active, focus on it — don't show
    # unrelated standalone story/component items that distract from the
    # current context.
    #
    # Project-level requirements are exempt. They are gates, not
    # distractions: `architecture_designed` and `issues_triaged` govern
    # whether the component work below them is even the right thing to do.
    # Suppressing them because some context happens to be mid-development
    # inverts the ordering the graph exists to enforce — the agent gets
    # handed component code while incoming issues sit untriaged and the
    # architecture is incoherent. `next_actionable/1` already sorts them
    # first; dropping them here is what made that invisible.
    standalone_to_show =
      case orchestrated_section do
        "" -> standalone
        _ -> Enum.filter(standalone, &(&1.entity_type == "project"))
      end

    standalone_sections =
      case standalone_to_show do
        [] -> ""
        nodes -> format_satisfied_by_groups(nodes, active_subagents)
      end

    [orchestrated_section, standalone_sections]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp format_satisfied_by_groups(nodes, active_subagents) do
    nodes
    |> group_by_preserving_order(& &1.satisfied_by)
    |> Enum.map_join("\n\n", fn {mod, group_nodes} ->
      name = short_module_name(mod)
      items = Enum.map_join(group_nodes, "\n", &orchestrate_node(&1, active_subagents))

      "### #{name}\n\n#{items}"
    end)
  end

  # Like Enum.group_by/2, but yields a list (not a map) ordered by the
  # position of each key's first occurrence in the input. Preserves
  # priority ordering from `next_actionable` — critical for rule 6
  # (story-linked components appear before unlinked ones).
  defp group_by_preserving_order(items, key_fn) do
    items
    |> Enum.reduce({[], %{}}, fn item, {keys, groups} ->
      key = key_fn.(item)

      if Map.has_key?(groups, key) do
        {keys, Map.update!(groups, key, &(&1 ++ [item]))}
      else
        {keys ++ [key], Map.put(groups, key, [item])}
      end
    end)
    |> then(fn {keys, groups} -> Enum.map(keys, &{&1, groups[&1]}) end)
  end

  defp orchestration_prompt(:develop_context) do
    """
    You are developing a bounded context.
    Implement the child components in dependency order.
    Develop schemas first, then fixtures and tests (if required), then code.
    """
  end

  defp orchestration_prompt(:develop_live_context) do
    "Develop Live Context — implement child LiveViews and LiveComponents"
  end

  defp orchestration_prompt(:develop_controller) do
    "Develop Controller — implement controller actions and views"
  end

  defp orchestration_prompt(other) do
    "#{other}"
  end

  defp orchestrate_node(node, active_subagents) do
    body = resolve_body(node)
    render_directive(node, body, active_subagents)
  end

  defp resolve_body(%{satisfied_by: mod} = node) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :dispatch, 1) do
      unwrap_body(mod.dispatch(node), node)
    else
      fallback_body(node)
    end
  end

  # Structured dispatch — `%{role: :qa, prompt: "..."}` — returned by task
  # modules whose sub-agent dispatch is role-keyed (story 810). Pass through
  # as a tagged tuple so `render_directive` can choose SendMessage vs spawn.
  defp unwrap_body(%{role: role, prompt: text}, _node) when is_atom(role) and is_binary(text) do
    %{role: role, prompt: text}
  end

  defp unwrap_body({:ok, text}, _node) when is_binary(text), do: text
  defp unwrap_body({:error, _reason}, node), do: fallback_body(node)
  defp unwrap_body(text, _node) when is_binary(text), do: text

  defp fallback_body(node), do: node.description || to_string(node.name)

  # Structured dispatch for sub-agent requirements: choose SendMessage to a
  # live sub-agent or fresh Agent spawn depending on the registry.
  defp render_directive(
         %{execution_type: :sub_agent} = node,
         %{role: role, prompt: text},
         active_subagents
       ) do
    role_key = to_string(role)

    case Map.get(active_subagents, role_key) do
      nil ->
        # No live sub-agent for this role — instruct a fresh Agent spawn.
        "- #{text} — Spawn Agent with role: :#{role} to call `start_task` with #{sig(node)}."

      agent_id ->
        # Live sub-agent registered — continue the existing conversation.
        "- #{text} — **SendMessage(to: #{agent_id})** role: :#{role}, `start_task` args: #{sig(node)}."
    end
  end

  # Plain-string or fallback dispatch for sub-agent tasks: parenthetical
  # metadata so the main agent can pass args to the sub-agent verbatim.
  defp render_directive(%{execution_type: :sub_agent} = node, body, _active_subagents)
       when is_binary(body) do
    "- #{body} (sub-agent start_task args: #{sig(node)})"
  end

  defp render_directive(node, body, _active_subagents) when is_binary(body) do
    if String.contains?(body, "requirement_name") do
      "- #{body}"
    else
      "- #{body} — call `start_task` with #{sig(node)}."
    end
  end

  defp sig(node) do
    "requirement_name=`#{node.name}`, entity_type=`#{node.entity_type}`, entity_id=`#{entity_ref(node)}`"
  end

  defp short_module_name(mod), do: mod |> inspect() |> String.split(".") |> List.last()

  @doc "Puts `:entity_number` on each story node, for rendering."
  def number_nodes(scope, nodes) do
    numbers =
      Map.new(Stories.story_numbers(scope), fn {id, number} -> {to_string(id), number} end)

    Enum.map(nodes, &number_node(&1, numbers))
  end

  # A story's entity_id is an integer from the projection and text from the
  # shadow, so it is compared as text.
  defp number_node(%{entity_type: "story", entity_id: id} = node, numbers),
    do: Map.put(node, :entity_number, Map.get(numbers, to_string(id)))

  defp number_node(node, _numbers), do: node

  @doc """
  Numbers the story nodes an execution offers.

  A copy with no active story is offered work from every story it holds, so
  the execution's own `story` cannot say which number each node carries.
  """
  def number_execution(scope, %{wave: wave, actionable: actionable} = execution) do
    %{execution | wave: number_nodes(scope, wave), actionable: number_nodes(scope, actionable)}
  end

  @doc """
  How a node is named to an agent: a story by its number, anything else by its
  id. A story node that was never numbered raises rather than printing its id,
  which `start_task` would read as some other story's number.
  """
  def entity_ref(%{entity_type: "story", entity_number: number}) when is_integer(number),
    do: number

  def entity_ref(%{entity_type: "story"} = node),
    do: raise(ArgumentError, "story node #{node.name} was rendered without its number")

  def entity_ref(%{entity_id: id}), do: id
end
