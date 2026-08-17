defmodule CodeMySpecSpex.Story690.Criterion5963Spex do
  @moduledoc """
  Story 690 — Browse and read project knowledge by path
  Criterion 5963 — Calling list_knowledge with no path returns the
  library root listing — the directories and files at the top level
  of the knowledge library.

  Surface: ListKnowledge MCP tool (knowledge library by default).
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "list_knowledge returns the library root listing" do
    scenario "Calling list_knowledge with no path returns root entries" do
      when_ "the agent calls list_knowledge with no path", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListKnowledge.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is not an error", context do
        refute context.response.isError == true,
               "expected list_knowledge to succeed, got: #{inspect(context.response)}"

        {:ok, context}
      end

      and_ "the response body renders the Knowledge Base header and at least one root entry",
           context do
        body = response_text(context.response)

        assert body =~ "Knowledge Base",
               "anchor: expected library title in the listing, got: #{inspect(body)}"

        assert body =~ "liveview/",
               "expected the priv/knowledge/liveview/ directory to appear in the root listing"

        {:ok, context}
      end
    end
  end
end
