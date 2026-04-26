defmodule CodeMySpecSpex.Story559.Criterion5159Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5159 — When upstream gates are satisfied and a story has
  zero acceptance criteria, the requirement graph surfaces
  `three_amigos_complete` scoped to that story as the next actionable
  requirement.

  This is the graph-wiring spec — it proves the node is in the project's
  story_graph with the right prereq, not the full agent flow.

  DRAFT. Depends on:
    - `three_amigos_complete` node added to a story-scoped graph
      (likely `RequirementDefinitionData.story_graph/0`) with
      prereq `[story_created]`.
    - `:persona_exists` shared given already creates a persona linked
      to a story with no AC; reusing it for setup. (Personas-complete
      may still be unsatisfied without summary.md/sources.md — if that
      blocks three_amigos_complete from surfacing, this spec needs to
      additionally seed those files like criterion 5141 does, or the
      graph needs personas_complete relaxed to "≥1 persona linked.")
  """

  use CodeMySpecSpex.Case

  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "graph surfaces three_amigos_complete on a story without AC" do
    scenario "next requirement names three_amigos_complete scoped to the story" do
      given_ :persona_exists

      when_ "the agent calls get_next_requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response surfaces three_amigos_complete for the story", context do
        body = response_text(context.response)

        assert body =~ ~r/requirement|next/i,
               "expected a real discovery response, got #{inspect(context.response)}"

        assert body =~ "three_amigos_complete",
               "expected response to name three_amigos_complete, got #{inspect(context.response)}"

        assert body =~ to_string(context.story.id),
               "expected response to reference story #{context.story.id}, got #{inspect(context.response)}"

        :ok
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
