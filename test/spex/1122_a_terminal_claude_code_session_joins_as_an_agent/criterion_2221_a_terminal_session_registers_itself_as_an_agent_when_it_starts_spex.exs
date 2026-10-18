defmodule CodeMySpecSpex.Story1122.Criterion2221Spex do
  @moduledoc """
  Story 1122 — A terminal Claude Code session joins as an agent.
  Criterion 2221 — A terminal session registers itself as an agent when it starts.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A terminal session registers itself as an agent when it starts", criterion: 2221 do
    scenario "a developer opens Claude Code on a checkout of the project" do
      given_ "a developer's checkout of the project, served by its harness", context do
        {:ok, HarnessHooks.ensure_live_harness(context)}
      end

      when_ "the plugin's SessionStart hook runs for a new session", context do
        session = session_id()
        {:ok, Map.merge(context, %{session: session, started: start_session(context, session)})}
      end

      then_ "an agent is registered for that session on the checkout's working copy", context do
        assert %{"provider" => "claude-code", "role" => "main"} =
                 agent = agent_for(context, context.started),
               inspect(agents(context))

        assert agent["working_copy"] == context.harness.root
        {:ok, context}
      end

      when_ "a session with the same Claude Code session id starts again", context do
        {:ok, Map.put(context, :again, start_session(context, context.session))}
      end

      then_ "the agent it answers with is the one keyed on that session id", context do
        assert context.again["agent_id"] == context.started["agent_id"]
        assert length(agents(context)) == 1
        {:ok, context}
      end
    end
  end
end
