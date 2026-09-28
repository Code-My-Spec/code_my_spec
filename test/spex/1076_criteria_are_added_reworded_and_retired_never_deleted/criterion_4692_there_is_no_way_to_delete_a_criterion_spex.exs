defmodule CodeMySpecSpex.Story1076.Criterion4692Spex do
  @moduledoc """
  Story 1076 — Criteria are added, reworded and retired, never deleted
  Criterion 4692 — There is no way to delete a criterion.

  Covers Rule "Criteria are retired, never deleted".

  The agent finds tools through `tool_docs`, so that is where it looks for a
  way to delete one.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.CodeMode.Tools.ToolDocs
  alias CodeMySpecSpex.CriterionScript

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only retiring is offered" do
    scenario "the agent looking for a way to delete a criterion finds retire" do
      given_ "a criterion on story A", context do
        CriterionScript.create_story(context.scope, "Story A", ["A thing the agent wants gone"])
        {:ok, context}
      end

      when_ "the agent looks for a way to delete it", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ToolDocs.execute(%{search: "criterion"}, frame)
        {:ok, Map.put(context, :docs, response_text(response))}
      end

      then_ "only retiring is offered", context do
        assert context.docs =~ "retire_criterion",
               "expected retire_criterion among the criterion tools. Got:\n#{context.docs}"

        refute context.docs =~ "delete_criterion",
               "a criterion can no longer be deleted, but delete_criterion is still offered. Got:\n#{context.docs}"

        {:ok, context}
      end
    end
  end
end
