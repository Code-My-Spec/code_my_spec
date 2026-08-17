defmodule CodeMySpecSpex.Story715.Criterion6305Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6305 — dependency_count sort puts components with most total deps first.

  When the agent calls `context_statistics` with
  `sort_by = "dependency_count"`, the response orders components by
  total dependency count (outgoing + incoming) descending. Each entry
  carries `outgoing`, `incoming`, and `total` dependency counts.

  Surface: `ContextStatistics` MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.ContextStatistics

  import CodeMySpecSpex.GraphGivens

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "context_statistics returns per-component story + dependency counts, sortable by story_count or dependency_count" do
    scenario "dependency_count sort puts components with most total deps first" do
      given_ :cross_context_dependency

      when_ ~s|the agent calls context_statistics with sort_by = "dependency_count"|, context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ContextStatistics.execute(%{sort_by: "dependency_count"}, frame)

        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "a dependency-linked context appears before the dependency-free schema child",
            context do
        # Stories has 1 outgoing → Users (total 1). Stories.Story is a schema
        # child with 0 deps. Sort by dependency_count desc must place
        # Stories above Stories.Story in the rendered list.
        ctx_pos = position_of(context.body, "\"module_name\":\"Stories\"")
        child_pos = position_of(context.body, "Stories.Story")

        assert is_integer(ctx_pos), "expected Stories context in response, got:\n#{context.body}"

        assert is_integer(child_pos),
               "expected Stories.Story child in response, got:\n#{context.body}"

        assert ctx_pos < child_pos,
               "expected Stories (1 dep) to appear before Stories.Story (0 deps), got positions #{ctx_pos} vs #{child_pos}"

        {:ok, context}
      end

      and_ "each entry carries outgoing, incoming, and total dependency counts", context do
        for key <- ~w(outgoing incoming total) do
          assert context.body =~ ~r/"#{key}":\s*\d+/,
                 "expected dependency_counts.#{key} in response, got:\n#{context.body}"
        end

        {:ok, context}
      end
    end
  end

  defp position_of(text, needle), do: match_pos(:binary.match(text, needle))

  defp match_pos({pos, _}), do: pos
  defp match_pos(:nomatch), do: nil
end
