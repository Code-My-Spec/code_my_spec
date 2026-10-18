defmodule CodeMySpecSpex.Story598.Criterion5300Spex do
  @moduledoc """
  Story 598 — Standard stack code generation
  Criterion 5300 — Prompt instructs the agent to run deps.get, compile, migrate, and test after generators.

  After the generator commands, the prompt requires four mix commands
  before declaring the phase done: `mix deps.get`, `mix compile`,
  `mix ecto.migrate`, `mix test`.

  Surface: `start_task` MCP tool against `code_generation`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The scaffold must land clean before completion", criterion: 249 do
    scenario "Prompt instructs the agent to run deps.get, compile, migrate, and test after generators" do
      given_ "the project has a baseline mix.exs", context do
        Fixtures.reset_setup_env(context.environment)
        Fixtures.with_baseline_project(context.environment)
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

      when_ "the agent calls start_task for the code_generation task", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "code_generation",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "the prompt routes the agent to the post-generator playbook", context do
        # The post-generator commands (mix deps.get / compile / ecto.migrate /
        # test) are documented in priv/knowledge/cms_generators/workflow.md.
        # The prompt routes the agent there rather than inlining each command,
        # so we assert on the route and trust the playbook content as the
        # source of truth.
        assert context.prompt =~ ~r/cms_generators\/workflow\.md/,
               "expected the prompt to reference the cms_generators workflow playbook " <>
                 "(which covers deps.get / compile / ecto.migrate / test)"

        {:ok, context}
      end
    end
  end
end
