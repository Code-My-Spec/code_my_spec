defmodule CodeMySpecSpex.Story669.Criterion5562Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5562 — Top-level component renders no-parent placeholder.

  Surface: `start_task` MCP tool against a `test_file` requirement on a
  top-level (parent-less) Component. The prompt the agent receives
  must explicitly note that there is no parent design rather than
  inserting a stale or fabricated parent path.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Top-level component renders no-parent placeholder" do
      given_ "a top-level context Component exists with no parent component", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story669.Orphan",
            name: "Story669 Orphan"
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

      then_ "the prompt's parent context line reads 'no parent design'", context do
        assert context.prompt =~ "Parent Context Design File: no parent design",
               "expected a 'no parent design' placeholder in the prompt, got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
