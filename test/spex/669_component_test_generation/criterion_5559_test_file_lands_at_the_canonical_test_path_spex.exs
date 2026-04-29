defmodule CodeMySpecSpex.Story669.Criterion5559Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5559 — Test file lands at the canonical test path.

  Surface: `start_task` MCP tool against a `test_file` requirement on a
  context-typed Component. The prompt the agent receives must instruct
  it to write the test file at the canonical path derived from the
  component's module name.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Test file lands at the canonical test path" do
      given_ "a context Component exists with no test file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story669.TestPath",
            name: "Story669 Test Path"
          )

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
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

      then_ "the prompt directs the agent to write at the canonical test path", context do
        assert context.prompt =~ "Write the test file to",
               "expected the prompt to instruct where to write the test file"

        assert context.prompt =~ "test/story669/test_path_test.exs",
               "expected the canonical test path derived from the module name, got: #{context.prompt}"

        {:ok, context}
      end
    end
  end
end
