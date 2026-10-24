defmodule CodeMySpecSpex.Story560.Criterion5151Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5151 — Optional section is accepted alongside required ones.
  Adding a Jobs to Be Done section (optional) to a fully-sectioned summary
  still passes validation.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  import CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.HarnessHooks
  alias CodeMySpecSpex.ProjectStateFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "summary includes an optional Jobs to Be Done section", criterion: 193 do
    scenario "validation passes and graph advances" do
      given_ :persona_exists

      # What the graph wants before the folder exists. Without it the refute
      # below cannot fail: a response that never mentions `personas_complete`
      # satisfies "it cleared" whether or not anything changed.
      given_ "the persona folder is still empty", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        before =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :before_response, before)}
      end

      given_ "summary.md includes optional Jobs to Be Done section", context do
        :ok =
          ExecutionContexts.write_file(
            context.execution_context,
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
          ExecutionContexts.write_file(
            context.execution_context,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "- https://example.com — Source — 2026-04-23\n"
          )

        {:ok, context}
      end

      given_ :persona_research_task_started

      when_ "the agent fires the stop hook and asks for next work", context do
        context = HarnessHooks.serve_in_memory(context)

        # This copy reads the fixture's in-memory runtime, which no harness
        # scans, so the fixture syncs what was written before the stop hook.
        ProjectStateFixtures.synced(context)

        HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session_id})

        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "get_next_requirement",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :next_response, response)}
      end

      then_ "personas_complete was what the graph wanted beforehand", context do
        assert response_text(context.before_response) =~ "personas_complete",
               "expected persona research to be outstanding while the folder was empty — " <>
                 "without that, the refute below cannot fail"

        {:ok, context}
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
