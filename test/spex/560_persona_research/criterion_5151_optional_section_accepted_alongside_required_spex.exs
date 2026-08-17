defmodule CodeMySpecSpex.Story560.Criterion5151Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5151 — Optional section is accepted alongside required ones.
  Adding a Jobs to Be Done section (optional) to a fully-sectioned summary
  still passes validation.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "summary includes an optional Jobs to Be Done section" do
    scenario "validation passes and graph advances" do
      given_ :persona_exists

      given_ "summary.md includes optional Jobs to Be Done section", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            """
            # Founder

            ## Role
            Solo founder.

            ## Goals
            Ship.

            ## Pain Points
            Switching.

            ## Context
            One person.

            ## Decision Drivers
            Speed.

            ## Evidence
            Notes.

            ## Jobs to Be Done
            Hire a harness that does the thinking so I don't have to.
            """
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "- https://example.com — Source — 2026-04-23\n"
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

      then_ "personas_complete clears — optional section did not block", context do
        body = response_text(context.next_response)

        refute body =~ "personas_complete",
               "expected personas_complete to clear with optional section included"

        {:ok, context}
      end
    end
  end
end
