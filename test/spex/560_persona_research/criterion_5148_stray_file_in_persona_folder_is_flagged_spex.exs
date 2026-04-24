defmodule CodeMySpecSpex.Story560.Criterion5148Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5148 — Stray file in the persona folder is flagged. Only
  summary.md and sources.md belong in the folder; any other file causes
  the checker to fail with the stray file named.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "agent writes a stray notes.md alongside the two allowed files" do
    scenario "hook feedback names the stray file" do
      given_ :persona_exists

      given_ "summary.md, sources.md, and a stray notes.md exist", context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/summary.md",
            "# Founder\n\n## Role\nSolo.\n\n## Goals\nShip.\n\n## Pain Points\nSwitching.\n\n## Context\nOne person.\n\n## Decision Drivers\nSpeed.\n\n## Evidence\nNotes.\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/sources.md",
            "- https://example.com — Source — 2026-04-23\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/personas/#{context.persona_slug}/notes.md",
            "stray research notes"
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

      then_ "feedback names notes.md as the stray file", context do
        body = response_text(context.response)

        assert body =~ ~r/Needs work|incomplete|stray/i, "expected failure feedback"
        assert body =~ "notes.md", "expected feedback to name the stray notes.md"

        :ok
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
end
