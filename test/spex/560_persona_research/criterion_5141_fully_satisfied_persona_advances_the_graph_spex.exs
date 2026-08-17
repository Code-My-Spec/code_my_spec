defmodule CodeMySpecSpex.Story560.Criterion5141Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5141 — When one persona on the project has a record + summary.md +
  sources.md, the personas_complete requirement clears and the graph surfaces
  a downstream requirement on the next get_next_requirement call.

  This is the happy-path end-to-end spec. Every prior criterion exercises a
  failure mode; this one proves the pipeline actually advances when the
  contract is satisfied.

  DRAFT. Depends on:
    - `CreatePersona` MCP tool (backing `:persona_exists` shared given).
    - `personas_complete` node wired with `PersonasChecker.complete?/1`.
    - `AgentTasks.PersonaResearch` + `evaluate/2`.
    - `persona_summary` document type registered.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent completes persona research end to end" do
    scenario "personas_complete clears and the graph advances" do
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

      given_ "sources.md is written with one cited source", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            minimal_sources()
          )

        {:ok, context}
      end

      given_ :persona_research_task_started

      when_ "the agent fires the stop hook", context do
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/hooks/stop", %{"session_id" => context.session_id})
          |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :stop_response, response)}
      end

      then_ "the next requirement is no longer personas_complete", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        body = response_text(response)

        # Anchor: a real discovery response came back — either another
        # requirement or an "all satisfied" marker. Either way, it must not
        # still be personas_complete.
        assert body =~ ~r/requirement|satisfied|complete/i,
               "expected a real discovery response from get_next_requirement"

        refute body =~ "personas_complete",
               "expected the graph to advance past personas_complete once artifacts exist"

        {:ok, context}
      end
    end
  end

  defp minimal_persona_summary do
    """
    # Founder

    ## Role
    Solo founder building a product without hiring a team.

    ## Goals
    Ship features continuously without losing context.

    ## Pain Points
    Context-switching across product, engineering, and marketing.

    ## Context
    One-person team, weekly release cadence.

    ## Decision Drivers
    Speed-to-ship and autonomy over polish.

    ## Evidence
    Internal notes; customer interviews pending.
    """
  end

  defp minimal_sources do
    """
    # Sources

    - https://example.com/interview — Founder interview — 2026-04-23
    """
  end
end
