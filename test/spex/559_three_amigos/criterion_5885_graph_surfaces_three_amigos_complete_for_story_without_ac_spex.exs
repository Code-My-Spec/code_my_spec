defmodule CodeMySpecSpex.Story559.Criterion5885Spex do
  @moduledoc """
  Story 559 — Three Amigos
  Criterion 5885 — When upstream gates are satisfied and a story has
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

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "graph surfaces three_amigos_complete on a story without AC" do
    scenario "list_requirements names three_amigos_complete scoped to the story as unsatisfied" do
      given_ :persona_exists

      # Use list_requirements (not get_next_requirement) — get_next
      # resyncs from disk and would wipe the in-memory test fixtures
      # before computing the actionable set.
      when_ "the agent calls list_requirements", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the rendered list surfaces three_amigos_complete for the story as unsatisfied",
            context do
        body = response_text(context.response)

        assert body =~ ~r/requirement/i,
               "expected a real discovery response, got #{inspect(context.response)}"

        assert body =~ ~r/\[ \]\s+\*\*three_amigos_complete\*\*/,
               "expected three_amigos_complete to render as unsatisfied for the story, got #{inspect(context.response)}"

        assert body =~ context.story.title,
               "expected response to reference the story by title #{inspect(context.story.title)}, got #{inspect(context.response)}"

        {:ok, context}
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
