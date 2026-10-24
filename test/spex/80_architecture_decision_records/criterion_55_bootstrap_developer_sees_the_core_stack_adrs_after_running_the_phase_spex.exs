defmodule CodeMySpecSpex.Story80.Criterion5269Spex do
  @moduledoc """
  Story 80 — Architecture Decision Records
  Criterion 5269 — Bootstrap developer sees the core stack ADRs after running the phase.

  A fresh project ends up with elixir/phoenix/liveview/tailwind/daisyui
  ADRs on disk after `start_task` runs against `technical_strategy`.

  Surface: `start_task` MCP tool against the `technical_strategy`
  requirement.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Pre-made decisions are auto-written before the prompt", criterion: 55 do
    scenario "Bootstrap developer sees the core stack ADRs after running the phase" do
      given_ "the project has no decision files on disk", context do
        Fixtures.reset_setup_env(context.execution_context)

        refute Fixtures.adr_exists?(context.execution_context, "elixir")
        refute Fixtures.adr_exists?(context.execution_context, "phoenix")

        {:ok, context}
      end

      given_ "a live harness serves the checkout", context do
        {:ok, HarnessHooks.ensure_live_harness(context, execution_context: :in_memory)}
      end

      given_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        HarnessHooks.post_hook(context, "session-start", %{"session_id" => session_id})

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the agent calls start_task for the technical_strategy task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        _response =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "technical_strategy",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, context}
      end

      then_ "each core stack ADR exists on disk", context do
        env = context.execution_context

        for topic <- ~w(elixir phoenix liveview tailwind daisyui) do
          assert Fixtures.adr_exists?(env, topic),
                 "expected ADR for #{topic} to exist after start_task"
        end

        {:ok, context}
      end
    end
  end
end
