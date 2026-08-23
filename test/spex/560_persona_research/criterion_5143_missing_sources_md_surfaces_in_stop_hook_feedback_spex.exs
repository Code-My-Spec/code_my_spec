defmodule CodeMySpecSpex.Story560.Criterion5143Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5143 — When a persona has a record and summary.md but no sources.md,
  the stop-hook feedback after a persona research task identifies the slug and
  the missing file.

  DRAFT. Depends on:
    - `personas_complete` node wired into
      `CodeMySpec.Requirements.RequirementDefinitionData.project_graph/0` with
      `check_type: :delegate` pointing at `PersonasChecker.complete?/1`.
    - `CodeMySpec.AgentTasks.PersonaResearch` with `command/2` + `evaluate/2`.
    - `personas` table migration + schema.
    - MCP tool `CodeMySpec.McpServers.Personas.Tools.CreatePersona` exposing
      persona creation as the real contract surface.
    - `persona_summary` document type registered with
      `CodeMySpec.Documents.Registry`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent stops with persona 'founder' missing sources.md" do
    scenario "stop hook feedback names 'founder' and sources.md" do
      given_ :persona_exists

      given_ "summary.md is written with all required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            minimal_persona_summary()
          )

        {:ok, context}
      end

      # sources.md deliberately not written — that's the gap under test.

      given_ "a persona research task is started", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "personas_complete",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: session_id
            },
            frame
          )

        {:ok,
         context
         |> Map.put(:session_id, session_id)
         |> Map.put(:task_id, extract_task_id(response))}
      end

      when_ "the agent calls evaluate_task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the response feedback names 'founder'", context do
        body = response_text(context.response)

        # Anchor: confirm the hook is actually blocking with real detail
        # (not an empty allow response) before asserting specifics.
        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected stop response to carry blocking feedback, got #{inspect(context.response)}"

        assert body =~ context.persona_slug,
               "expected feedback to name the persona slug"

        {:ok, context}
      end

      then_ "the response feedback names sources.md as the missing artifact", context do
        assert response_text(context.response) =~ "sources.md",
               "expected feedback to name sources.md as the missing file"

        {:ok, context}
      end
    end
  end

  defp extract_task_id(response),
    do: extract_task_id_from(Regex.run(~r/Task ID: `([^`]+)`/, response_text(response)), response)

  defp extract_task_id_from([_, task_id], _response), do: task_id

  defp extract_task_id_from(_, response),
    do: raise("Could not extract task ID from response: #{inspect(response)}")

  defp minimal_persona_summary do
    """
    # Founder

    ## Role
    Solo founder building a product without hiring a team.

    ## Goals
    Ship features continuously without losing context between product and code.

    ## Pain Points
    Context-switching across product, engineering, and marketing burns the week.

    ## Context
    One-person team, limited budget, weekly release cadence.

    ## Decision Drivers
    Speed-to-ship and autonomy dominate polish.

    ## Evidence
    Internal notes; customer interviews pending.
    """
  end
end
