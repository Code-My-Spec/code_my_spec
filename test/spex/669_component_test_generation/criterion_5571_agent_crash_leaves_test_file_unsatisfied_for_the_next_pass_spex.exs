defmodule CodeMySpecSpex.Story669.Criterion5571Spex do
  @moduledoc """
  Story 669 — Component Test Generation
  Criterion 5571 — Agent crash leaves test_file unsatisfied for the next pass.

  Surface: `start_task` followed by `list_requirements`. After the agent
  task fires for `test_file` but the agent exits without producing a
  test file (modeled by writing nothing between `start_task` and the
  next observation), `test_file` remains unsatisfied — the graph is
  honest about the missing artifact and re-fires on the next pass.
  """

  use CodeMySpecSpex.Case

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.ListRequirements
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.ComponentHelpers
  alias CodeMySpecSpex.TaskResponseHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Component Test Generation" do
    scenario "Agent crash leaves test_file unsatisfied for the next pass" do
      given_ "a context Component exists with no test file on disk", context do
        component =
          ComponentHelpers.create(context.scope,
            type: "context",
            module_name: "Story669.NoTest",
            name: "Story669 NoTest"
          )

        {:ok, Map.put(context, :component, component)}
      end

      given_ "the agent has signalled session start and called start_task", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "test_file",
              entity_type: "component",
              entity_id: to_string(context.component.id),
              session_id: session_id
            },
            frame
          )

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent exits without writing any file and the next graph pass observes state",
            context do
        # Agent crash modeled by writing nothing between start_task and observation.
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = ListRequirements.execute(%{}, frame)

        {:ok, Map.put(context, :response_text, TaskResponseHelpers.response_text(response))}
      end

      then_ "test_file for the component remains unsatisfied", context do
        assert context.response_text =~ "Story669.NoTest",
               "expected the response to mention the component scope"

        assert context.response_text =~ ~r/\[ \]\s+\*\*test_file\*\*/,
               "expected test_file to stay unsatisfied — graph must not silently advance past missing artifacts"

        {:ok, context}
      end
    end
  end
end
