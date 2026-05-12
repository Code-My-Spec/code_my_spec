defmodule CodeMySpecSpex.Story690.Criterion5967Spex do
  @moduledoc """
  Story 690 — Browse and read project knowledge by path
  Criterion 5967 — Library selection defaults to `knowledge` when the
  `library` parameter is omitted. Unknown library names are rejected
  with a validation error.

  Surface: ListKnowledge MCP tool.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Library selection defaults to knowledge; unknown libraries are rejected" do
    scenario "Omitting the library parameter defaults to the knowledge library" do
      when_ "the agent calls list_knowledge with no library parameter", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = ListKnowledge.execute(%{}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the call returns the framework Knowledge Base listing", context do
        refute context.response.isError == true,
               "expected list_knowledge to succeed when library is omitted, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "Knowledge Base",
               "expected the default library to be `knowledge` (title: Knowledge Base)"

        {:ok, context}
      end
    end

    scenario "Unknown library names are rejected with a validation error" do
      when_ ~s(the agent calls list_knowledge with library "bogus_library"), context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListKnowledge.execute(%{library: "bogus_library"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is an error naming the rejected library", context do
        assert context.response.isError == true,
               "expected an error response for the unknown library, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ "bogus_library",
               "expected the error to name the offending library, got: #{inspect(body)}"

        assert body =~ "knowledge" or body =~ "project_knowledge",
               "expected the error to instruct using one of the valid libraries"

        {:ok, context}
      end
    end
  end
end
