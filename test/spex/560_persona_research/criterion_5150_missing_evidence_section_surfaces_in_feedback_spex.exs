defmodule CodeMySpecSpex.Story560.Criterion5150Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5150 — When summary.md is present but missing the Evidence section,
  the stop-hook feedback names "Evidence" as the failed required section.

  Exercises the Documents-registry validation path through the real pipeline:
  PersonasChecker runs `CodeMySpec.Documents.create_dynamic_document/2` on
  summary.md against the persona_summary type, the validation error bubbles
  up through the delegate's markdown detail string, and the stop hook returns
  it in the feedback.

  DRAFT. Depends on:
    - persona_summary document type registered with
      CodeMySpec.Documents.Registry — required_sections must include "Evidence".
    - PersonasChecker running Documents validation and surfacing missing-section
      errors in its detail string (not just file existence).
    - :persona_exists and :persona_research_task_started shared givens.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent stops with summary.md missing the Evidence section" do
    scenario "feedback names the persona slug and the Evidence section" do
      given_ :persona_exists

      given_ "summary.md is written without the Evidence section", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            summary_missing_evidence()
          )

        {:ok, context}
      end

      given_ "sources.md is written", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "# Sources\n\n- https://example.com — Source — 2026-04-23\n"
          )

        {:ok, context}
      end

      given_ :persona_research_task_started

      when_ "the agent calls evaluate_task", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CodeMySpec.McpServers.Tasks.Tools.EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the feedback names the persona slug and 'Evidence'", context do
        body = response_text(context.response)

        # Anchor: confirm failure feedback is real before asserting specifics.
        assert body =~ ~r/Needs work|incomplete|missing|invalid/i,
               "expected failure feedback, got #{inspect(context.response)}"

        assert body =~ context.persona_slug,
               "expected feedback to name the persona slug"

        assert body =~ ~r/evidence/i,
               "expected feedback to name Evidence as the missing required section, got #{inspect(context.response)}"

        {:ok, context}
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end

  defp response_text(other), do: inspect(other)

  defp summary_missing_evidence do
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
    """
  end
end
