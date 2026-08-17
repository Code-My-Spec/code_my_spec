defmodule CodeMySpecSpex.Story560.Criterion5129Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5129 — Satisfied requirement releases the next graph node. When
  record + summary.md + sources.md all exist for a linked persona, the
  checker passes and the graph advances past personas_complete.

  (Mirror of criterion 5141, framed as the "release" side of the contract.)
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent writes all three artifacts for a linked persona" do
    scenario "personas_complete node clears and graph advances" do
      given_ :persona_exists

      given_ "summary.md and sources.md are written", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            minimal_summary()
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "# Sources\n\n- https://example.com — Source — 2026-04-23\n"
          )

        {:ok, context}
      end

      given_ :persona_research_task_started

      when_ "the agent fires the stop hook and asks for next work", context do
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/stop", %{"session_id" => context.session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :next_response, response)}
      end

      then_ "personas_complete is no longer the blocking requirement", context do
        body = response_text(context.next_response)

        # Anchor: a real discovery response came back.
        assert body =~ ~r/requirement|satisfied|complete/i

        refute body =~ "personas_complete",
               "expected the graph to advance past personas_complete once all artifacts exist"

        {:ok, context}
      end
    end
  end

  defp minimal_summary do
    """
    # Founder

    ## Role
    Solo founder.

    ## Goals
    Ship without hiring.

    ## Pain Points
    Context switching.

    ## Context
    One-person team.

    ## Decision Drivers
    Speed.

    ## Evidence
    Internal notes; customer interviews pending.
    """
  end
end
