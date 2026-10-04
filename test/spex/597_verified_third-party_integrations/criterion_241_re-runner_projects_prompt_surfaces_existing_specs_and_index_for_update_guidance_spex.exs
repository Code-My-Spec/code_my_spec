defmodule CodeMySpecSpex.Story597.Criterion5288Spex do
  @moduledoc """
  Story 597 — Verified third-party integrations
  Criterion 5288 — Re-runner project's prompt surfaces existing specs and index for update guidance.

  A re-runner with prior specs and an index gets a prompt that lists
  the existing integration specs, includes an Existing Index section,
  and instructs updating rather than recreating.

  Surface: `start_task` MCP tool against `qa_integration_plan`.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The prompt grounds itself in real project state", criterion: 241 do
    scenario "Re-runner project's prompt surfaces existing specs and index for update guidance" do
      given_ "a twilio spec and integrations index already exist", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
        Fixtures.with_verified_integration(context.environment, "twilio")
        {:ok, context}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the qa_integration_plan task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "qa_integration_plan",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt contains an Existing Integration Specs section listing twilio",
            context do
        assert context.prompt =~ "Existing Integration Specs",
               "expected the existing-specs section to be rendered"

        assert context.prompt =~ "twilio",
               "expected the existing twilio spec to be surfaced"

        {:ok, context}
      end

      and_ "the prompt contains an Existing Index section", context do
        assert context.prompt =~ "## Existing Index",
               "expected the existing-index section to be rendered"

        {:ok, context}
      end

      and_ "the prompt instructs updating rather than recreating", context do
        assert context.prompt =~ ~r/update.*rather than/i,
               "expected the update-rather-than-recreate guidance"

        {:ok, context}
      end
    end
  end
end
