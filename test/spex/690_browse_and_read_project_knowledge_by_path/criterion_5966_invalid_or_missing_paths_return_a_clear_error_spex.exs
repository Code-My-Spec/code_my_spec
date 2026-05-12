defmodule CodeMySpecSpex.Story690.Criterion5966Spex do
  @moduledoc """
  Story 690 — Browse and read project knowledge by path
  Criterion 5966 — Calling the tools with an invalid or missing path
  returns a clear error response rather than crashing. Path-traversal
  attempts (`..`) are rejected as invalid.

  Surface: ReadKnowledge + ListKnowledge MCP tools.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge
  alias CodeMySpec.McpServers.Knowledge.Tools.ReadKnowledge

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Bad paths return error responses, not crashes" do
    scenario "read_knowledge on a missing file returns a not-found error" do
      when_ ~s(the agent calls read_knowledge with a missing path "does_not_exist.md"),
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ReadKnowledge.execute(%{path: "does_not_exist.md"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is an error naming the missing path", context do
        assert context.response.isError == true,
               "expected an error response, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ ~r/not found/i,
               "expected the error message to indicate the path was not found, got: #{inspect(body)}"

        assert body =~ "does_not_exist.md",
               "expected the error message to name the offending path"

        {:ok, context}
      end
    end

    scenario "list_knowledge rejects a path-traversal attempt as invalid" do
      when_ "the agent calls list_knowledge with a path-traversal attempt", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListKnowledge.execute(%{path: "../../etc/passwd"}, frame)

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response is an error referring to the invalid path", context do
        assert context.response.isError == true,
               "expected an error response, got: #{inspect(context.response)}"

        body = response_text(context.response)

        assert body =~ ~r/invalid path/i,
               "expected the error message to indicate the path was invalid, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
