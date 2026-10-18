defmodule CodeMySpecSpex.Story1123.Criterion2247Spex do
  @moduledoc """
  Story 1123 — A terminal agent is told things like any agent.
  Criterion 2247 — A terminal agent whose inbound is held or refused, or whose Claude Code is too old, falls back to the stop hook and says why.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A terminal agent its inbox cannot reach is told at its stop, and everyone hears why",
    criterion: 2247 do
    scenario "a session whose Claude Code names no inbox socket" do
      given_ "a terminal agent whose Claude Code has no inbox socket", context do
        context = HarnessHooks.ensure_live_harness(context)
        session = session_id()
        started = start_session(context, session)
        {:ok, Map.merge(context, %{session: session, started: started})}
      end

      then_ "the agent is told why messages will reach it when it stops", context do
        said = context.started["hookSpecificOutput"]["additionalContext"]
        assert said =~ "no messaging socket"
        assert said =~ "when you stop"
        {:ok, context}
      end

      when_ "main sends it a message", context do
        sent =
          ToolLibrary.run(
            "message_agent",
            %{"agent_id" => context.started["agent_id"], "message" => "Check the failing spex."},
            %{scope: context.scope}
          )

        {:ok, Map.put(context, :sent, sent)}
      end

      then_ "main is told why it was not delivered now", context do
        assert {:ok, said} = context.sent
        assert said =~ "no live inbox"
        assert said =~ "when it next stops"
        {:ok, context}
      end

      when_ "the session stops", context do
        {:ok,
         Map.put(
           context,
           :stopped,
           HarnessHooks.post_hook(context, "stop", %{"session_id" => context.session})
         )}
      end

      then_ "the message is delivered through the stop hook", context do
        assert %{"decision" => "block", "reason" => reason} = context.stopped
        assert reason =~ "Check the failing spex."
        {:ok, context}
      end
    end
  end
end
