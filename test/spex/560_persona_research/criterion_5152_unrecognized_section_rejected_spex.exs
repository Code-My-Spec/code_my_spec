defmodule CodeMySpecSpex.Story560.Criterion5152Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5152 — Unrecognized section is rejected. A summary with an
  unknown section name like "Demographics" fails validation, and the
  stop-hook feedback names the disallowed section.
  """

  use CodeMySpecSpex.Case
  import CodeMySpecSpex.SharedGivens

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "summary includes an unrecognized Demographics section" do
    scenario "hook feedback names Demographics as disallowed" do
      given_ :persona_exists

      given_ "summary.md includes an unrecognized Demographics section", context do
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

            ## Demographics
            Not an allowed section.
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

      when_ "the agent calls evaluate_task", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          CodeMySpec.McpServers.Tasks.Tools.EvaluateTask.execute(
            %{task_id: context.task_id, session_id: context.session_id},
            frame
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

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end

  defp response_text(other), do: inspect(other)
end
