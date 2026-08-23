defmodule CodeMySpecSpex.Story669.Criterion5563Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5563 — Child component prompt references parent context spec.

  Surface: `start_task` MCP tool against a `test_file` requirement on a
  child Component whose parent context is already known. The prompt
  the agent receives must include the parent context's spec file path
  so the agent can read the parent design before writing the child's
  tests.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Child component prompt references parent context spec" do
      given_ "a parent context Component exists", context do
        parent =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story669.ParentCtx",
            name: "Story669 ParentCtx"
          )

        {:ok, Map.put(context, :parent, parent)}
      end

      given_ "a child Component is linked to the parent context", context do
        child =
          ComponentHelpers.create(context.scope,
            type: "module",
            module_name: "Story669.ParentCtx.Item",
            name: "Story669 ParentCtx Item",
            parent_component_id: context.parent.id
          )

        {:ok, Map.put(context, :child, child)}
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

      when_ "the agent calls start_task for the child's test_file requirement", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_file",
              entity_type: "component",
              entity_id: to_string(context.child.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, TaskResponseHelpers.response_text(response))}
      end

      then_ "the prompt names the parent context's spec file path", context do
        assert context.prompt =~
                 "Parent Context Design File: .code_my_spec/spec/story669/parent_ctx.spec.md",
               "expected the prompt to reference the parent's spec path, got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
