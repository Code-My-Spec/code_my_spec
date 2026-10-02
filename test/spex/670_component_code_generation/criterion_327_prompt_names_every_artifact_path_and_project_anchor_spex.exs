defmodule CodeMySpecSpex.Story670.Criterion5582Spex do
  @moduledoc """
  Story 670 — Component Code Generation
  Criterion 5582 — Prompt names every artifact path and project anchor.

  Surface: `start_task` MCP tool against the `implementation_file`
  requirement on a context Component. The prompt the agent receives
  must be self-sufficient — naming the test and code paths and where
  the component's design is read
  plus project and component anchors in a single block so the coding
  agent never has to ask where things live.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Code Generation", criterion: 327 do
    scenario "Prompt names every artifact path and project anchor" do
      given_ :synced_context_component

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the implementation_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "implementation_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the prompt names every artifact and project anchor", context do
        prompt = context.prompt
        component = context.component
        project = context.project

        assert prompt =~ "get_component",
               "expected the prompt to say where the design is read, got: #{prompt}"

        refute prompt =~ ".spec.md",
               "components are records; a spec file describes nothing: #{prompt}"

        assert prompt =~ "lib/example_context.ex",
               "expected the target code file path in the prompt"

        assert prompt =~ "test/example_context_test.exs",
               "expected the test file path in the prompt"

        assert prompt =~ project.name,
               "expected the project name in the prompt"

        assert prompt =~ component.name,
               "expected the component name in the prompt"

        assert prompt =~ to_string(component.type),
               "expected the component type in the prompt"

        {:ok, context}
      end
    end
  end
end
