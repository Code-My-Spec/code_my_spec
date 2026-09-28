defmodule CodeMySpecSpex.Story560.Criterion5149Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5149 — Fully-sectioned summary validates. When summary.md has
  all six required sections (Role, Goals, Pain Points, Context, Decision
  Drivers, Evidence) plus correct structure, the checker passes and the
  graph advances past personas_complete.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

    alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ProjectStateFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent writes a valid summary with all required sections", criterion: 191 do
    scenario "graph clears personas_complete after stop hook" do
      given_ :persona_exists

      # What the graph wants before the folder exists. Without it the refute
      # below cannot fail: a response that never mentions `personas_complete`
      # satisfies "it is no longer there" whether or not anything changed.
      given_ "the persona folder is still empty", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, before, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :before_response, before)}
      end

      given_ "summary.md has all six required sections", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            """
            # Founder

            ## Role
            Solo founder.

            ## Goals
            Ship without hiring.

            ## Pain Points
            Context switching.

            ## Context
            Small team.

            ## Decision Drivers
            Speed and autonomy.

            ## Evidence
            Internal notes.
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
        # The harness syncs the checkout before it fires the stop hook — see
        # `Validation`, which skips `FileSync.sync_changed/2` "because the
        # harness has already done" it. There is no harness here, and the files
        # this scenario wrote are what the hook is about, so the fixture does it.
        #
        # This used to happen by accident further down: `GetNextRequirement`
        # opened with a full `FileSync.sync/2`, so files written any time before
        # the agent asked were picked up on the way to the graph. That made a
        # read responsible for a write's visibility and is gone (c83c5b58).
        ProjectStateFixtures.synced(context)

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/stop", %{"session_id" => context.session_id})
        |> Phoenix.ConnTest.json_response(200)

        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :next_response, response)}
      end

      then_ "personas_complete was what the graph wanted beforehand", context do
        assert response_text(context.before_response) =~ "personas_complete",
               "expected persona research to be outstanding while the folder was empty — " <>
                 "without that, the refute below cannot fail"

        {:ok, context}
      end

      then_ "personas_complete is no longer in the response", context do
        body = response_text(context.next_response)

        refute body =~ "personas_complete",
               "expected personas_complete to clear with a fully-sectioned summary"

        {:ok, context}
      end
    end
  end
end
