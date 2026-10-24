defmodule CodeMySpecSpex.Story560.Criterion5152Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5152 — Unrecognized section is rejected. A summary with an
  unknown section name like "Demographics" fails validation, and the
  stop-hook feedback names the disallowed section.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.ExecutionContexts

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "summary includes an unrecognized Demographics section", criterion: 194 do
    scenario "hook feedback names Demographics as disallowed" do
      given_ :persona_exists

      given_ "summary.md includes an unrecognized Demographics section", context do
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

            ## Demographics
            Not an allowed section.
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

      when_ "the agent calls evaluate_task", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "evaluate_task",
            %{task_id: context.task_id, session_id: context.session_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "feedback names Demographics as disallowed", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|disallow|invalid/i, "expected failure feedback"
        assert body =~ ~r/demographics/i, "expected feedback to name Demographics"

        {:ok, context}
      end
    end
  end
end
