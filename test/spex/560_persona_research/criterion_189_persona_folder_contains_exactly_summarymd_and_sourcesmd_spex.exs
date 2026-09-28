defmodule CodeMySpecSpex.Story560.Criterion5146Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5146 — Persona folder contains exactly summary.md and sources.md.
  Observable: when both files exist with valid content for a linked persona,
  the checker passes and the graph advances.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

    alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.ProjectStateFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent writes exactly summary.md and sources.md", criterion: 189 do
    scenario "checker accepts the folder and graph advances" do
      given_ :persona_exists

      # What the graph offers with the folder empty. The criterion's observable
      # is that writing the files *advances* it, and the refute below cannot
      # show that on its own: a response that never mentions
      # `personas_complete` satisfies "it is cleared" whether or not anything
      # changed. Both responses were `### TechnicalStrategy` — identical — so
      # the criterion held with the hook doing nothing at all.
      given_ "the persona folder is still empty", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}
        {:reply, before, _frame} = GetNextRequirement.execute(%{}, frame)

        {:ok, Map.put(context, :before_response, before)}
      end

      given_ :persona_research_task_started

      when_ "the agent writes both files, fires the stop hook and asks for next work",
            context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            "# Founder\n\n## Role\nSolo founder.\n\n## Goals\nShip.\n\n## Pain Points\nSwitching.\n\n## Context\nOne person.\n\n## Decision Drivers\nSpeed.\n\n## Evidence\nInternal notes.\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "- https://example.com — Source — 2026-04-23\n"
          )

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
               "expected persona research to be the outstanding requirement while the " <>
                 "folder was empty — without that, the refute below cannot fail"

        {:ok, context}
      end

      then_ "personas_complete is cleared from the actionable set", context do
        refute response_text(context.next_response) =~ "personas_complete",
               "expected personas_complete to clear when both files exist"

        {:ok, context}
      end
    end
  end
end
