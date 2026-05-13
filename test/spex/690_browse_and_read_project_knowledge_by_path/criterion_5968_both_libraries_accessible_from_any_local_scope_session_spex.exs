defmodule CodeMySpecSpex.Story690.Criterion5968Spex do
  @moduledoc """
  Story 690 — Browse and read project knowledge by path
  Criterion 5968 — Both `knowledge` and `project_knowledge` libraries
  are accessible from any local-scope agent session — no extra
  registration or configuration is required beyond an active project
  (which the tools resolve via Validators.validate_local_scope).

  Surface: ListKnowledge MCP tool against both libraries.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Knowledge.Tools.ListKnowledge

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Both knowledge libraries are reachable from a local-scope session" do
    scenario "Calling list_knowledge against both libraries succeeds" do
      given_ "the project_knowledge library has a README.md entry", context do
        # project_knowledge resolves to <scope.cwd>/.code_my_spec/knowledge
        # via scope.environment — write through the in-memory env so the
        # directory check and listing both see the entry.
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/knowledge/README.md",
            "# Project Knowledge\n\nTest fixture for criterion 5968.\n"
          )

        {:ok, context}
      end

      when_ ~s(the agent calls list_knowledge with library "knowledge"), context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListKnowledge.execute(%{library: "knowledge"}, frame)

        {:ok, Map.put(context, :knowledge_response, response)}
      end

      and_ ~s(the agent then calls list_knowledge with library "project_knowledge"),
           context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          ListKnowledge.execute(%{library: "project_knowledge"}, frame)

        {:ok, Map.put(context, :project_knowledge_response, response)}
      end

      then_ "the knowledge library call succeeds with the Knowledge Base listing", context do
        refute context.knowledge_response.isError == true,
               "expected `knowledge` library call to succeed, got: #{inspect(context.knowledge_response)}"

        body = response_text(context.knowledge_response)

        assert body =~ "Knowledge Base",
               "expected the Knowledge Base header in the response body"

        {:ok, context}
      end

      and_ "the project_knowledge library call also succeeds with its listing", context do
        refute context.project_knowledge_response.isError == true,
               "expected `project_knowledge` library call to succeed, got: #{inspect(context.project_knowledge_response)}"

        body = response_text(context.project_knowledge_response)

        assert body =~ "Project Knowledge",
               "expected the Project Knowledge header in the response body"

        {:ok, context}
      end
    end
  end
end
