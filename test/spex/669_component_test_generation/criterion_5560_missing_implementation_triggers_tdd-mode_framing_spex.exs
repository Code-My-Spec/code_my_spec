defmodule CodeMySpecSpex.Story669.Criterion5560Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5560 — Missing implementation triggers TDD-mode framing.

  Surface: `start_task` MCP tool against a `test_file` requirement on a
  Component whose implementation file does not exist on disk. The
  prompt the agent receives must instruct it to write only the test
  assertions defined in the design and note that adding cases requires
  modifying the design first.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Missing implementation triggers TDD-mode framing" do
      given_ "a context Component exists with no implementation file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story669.NoImpl",
            name: "Story669 NoImpl"
          )

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the test_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the prompt frames the work as TDD: write tests before the implementation", context do
        assert context.prompt =~ "doesn't exist yet",
               "expected the prompt to note the implementation doesn't exist, got: #{context.prompt}"

        assert context.prompt =~ "TDD",
               "expected the prompt to mention TDD framing"

        {:ok, context}
      end

      and_ "the prompt restricts the agent to test assertions defined in the design", context do
        assert context.prompt =~ "Test Assertions section",
               "expected the prompt to reference the design's Test Assertions section"

        assert context.prompt =~ ~r/modify the design/i,
               "expected the prompt to instruct the agent to modify the design first if more cases are wanted"

        {:ok, context}
      end
    end
  end
end
