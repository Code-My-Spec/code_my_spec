defmodule CodeMySpecSpex.Story715.Criterion6304Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6304 — Default story_count sort puts components with most stories first.

  When the project has components with varying story counts and the
  agent calls `context_statistics` with no `sort_by` parameter, the
  response orders components by story_count descending. The summary
  block also reports `total_components`, `total_stories`,
  `total_dependencies`, and `components_with_stories`.

  Surface: `ContextStatistics` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.ContextStatistics

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "context_statistics returns per-component story + dependency counts, sortable by story_count or dependency_count" do
    scenario "Default story_count sort puts components with most stories first" do
      given_ :story_with_liveview_surface
      given_ :orphan_component

      when_ "the agent calls context_statistics with no sort_by parameter", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ContextStatistics.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the story-linked component appears before the orphan in the response", context do
        live_pos = position_of(context.body, "Marketing.HomeLive")
        orphan_pos = position_of(context.body, "OrphanContext")

        assert is_integer(live_pos),
               "expected Marketing.HomeLive in response, got:\n#{context.body}"

        assert is_integer(orphan_pos), "expected OrphanContext in response, got:\n#{context.body}"

        assert live_pos < orphan_pos,
               "expected story-linked Marketing.HomeLive to appear before orphan OrphanContext, got positions #{live_pos} vs #{orphan_pos}"

        {:ok, context}
      end

      and_ "the summary reports the four count totals", context do
        for key <- ~w(total_components total_stories total_dependencies components_with_stories) do
          assert context.body =~ key,
                 "expected summary.#{key} in response, got:\n#{context.body}"
        end

        {:ok, context}
      end
    end
  end

  defp position_of(text, needle), do: match_pos(:binary.match(text, needle))

  defp match_pos({pos, _}), do: pos
  defp match_pos(:nomatch), do: nil
end
