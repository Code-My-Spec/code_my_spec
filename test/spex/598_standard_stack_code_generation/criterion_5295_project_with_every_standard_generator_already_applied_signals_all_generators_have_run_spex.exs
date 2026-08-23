defmodule CodeMySpecSpex.Story598.Criterion5295Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5295 — Project with every standard generator already applied signals all generators have run.

  When every standard generator's detection file is on disk, the prompt
  signals that all standard generators have already been run.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Generators run in dependency order with detection-based skipping" do
    scenario "Project with every standard generator already applied signals all generators have run" do
      given_ "every standard generator's detection file is present", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        Fixtures.with_all_generators_applied(context.environment)

        for id <- Fixtures.generator_ids() do
          assert Fixtures.generator_applied?(context.environment, id),
                 "expected #{id} detection file to be present"
        end

        {:ok, context}
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

      when_ "the agent calls start_task for the code_generation task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "code_generation",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt signals that all standard generators have already been run",
            context do
        assert context.prompt =~ "All standard generators have already been run.",
               "expected the all-applied marker phrase in the prompt"

        {:ok, context}
      end
    end
  end
end
