defmodule CodeMySpecSpex.Story669.Criterion5561Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5561 — Existing implementation triggers validation-mode framing.

  Surface: `start_task` MCP tool against a `test_file` requirement on a
  Component whose implementation file already exists on disk and is
  registered in the Files index. The prompt the agent receives must
  frame the work as validating the existing implementation against the
  design specification rather than driving development TDD-style.

  Setup uses `:synced_context_component` so the component's spec and
  impl files both exist and are picked up by the Files index — the
  same surface (sync LiveView click) the harness uses in production.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Existing implementation triggers validation-mode framing" do
      given_ :synced_context_component

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
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

      then_ "the prompt frames the work as validating the existing implementation", context do
        assert context.prompt =~ "implementation already exists",
               "expected the prompt to acknowledge the existing implementation, got: #{context.prompt}"

        assert context.prompt =~ ~r/validate.*against the.*design/i,
               "expected the prompt to instruct the agent to validate the implementation against the design"

        {:ok, context}
      end

      and_ "the prompt does not push TDD-style restrictions", context do
        refute context.prompt =~ "Only write the tests defined in the Test Assertions section",
               "expected the prompt to omit the TDD-only restriction when the implementation exists"

        {:ok, context}
      end
    end
  end
end
