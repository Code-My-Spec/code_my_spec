defmodule CodeMySpecSpex.Story560.Criterion5142Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5142 — Missing DB row fails evaluation. A persona folder with
  summary.md + sources.md but no personas row still fails the checker
  because the personas_complete check requires personas linked to the
  project via persona_stories (no row = no link = not counted).
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "files on disk without a DB record + link" do
    scenario "stop hook blocks because no persona is linked to the project" do
      given_ "files for an orphan slug are written to disk", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/orphan/summary.md",
            "# Orphan\n\n## Role\nOrphan.\n\n## Goals\nNone.\n\n## Pain Points\nNone.\n\n## Context\nNone.\n\n## Decision Drivers\nNone.\n\n## Evidence\nNone.\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/orphan/sources.md",
            "- https://example.com — Source — 2026-04-23\n"
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

      then_ "the hook blocks with a 'no personas' message", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|missing|invalid|no personas/i,
               "expected blocking feedback for a project with no linked personas"

        {:ok, context}
      end
    end
  end
end
