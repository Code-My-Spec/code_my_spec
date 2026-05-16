defmodule CodeMySpecSpex.Story715.Criterion6310Spex do
  @moduledoc """
  Story 715 — Architect surveys the project
  Criterion 6310 — orphaned_contexts lists contexts with no story and no dependencies.

  When the project has both an orphaned context (no story, no
  dependencies) and a story-linked context, `orphaned_contexts`
  returns the orphan and omits the story-linked context.

  Surface: `OrphanedContexts` MCP tool, backed by
  `Components.list_orphaned_contexts/1`.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Components.Tools.OrphanedContexts

  import CodeMySpecSpex.GraphGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "orphaned_contexts lists contexts with no story and no dependencies" do
    scenario "orphaned_contexts lists contexts with no story and no dependencies" do
      given_ :orphan_component

      given_ :story_with_liveview_surface

      when_ "the agent calls orphaned_contexts", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = OrphanedContexts.execute(%{}, frame)
        {:ok, Map.put(context, :body, response_text(response))}
      end

      then_ "the response lists the orphan context", context do
        assert context.body =~ "OrphanContext",
               "expected orphan context to appear, got:\n#{context.body}"

        {:ok, context}
      end

      and_ "the response does not list the story-linked context", context do
        refute context.body =~ ~r/\bMarketing\b/,
               "expected story-linked Marketing context to be excluded, got:\n#{context.body}"

        {:ok, context}
      end
    end
  end
end
