defmodule CodeMySpecSpex.Story1128.Criterion2290Spex do
  @moduledoc """
  Story 1128 — A terminal Codex agent is told things like any agent.
  Criterion 2290 — A Codex too old for codex queue gets its messages at stop.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalCodexHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp message(context, text, extra \\ %{}) do
    ToolLibrary.run(
      "message_agent",
      Map.merge(%{"agent_id" => context.agent_id, "message" => text}, extra),
      %{scope: context.scope}
    )
  end

  spex "A Codex without codex queue is told at its stop, and everyone hears why",
    criterion: 2290 do
    scenario "main messages a terminal Codex agent whose Codex has no queue command" do
      given_ "a terminal Codex agent whose Codex has no queue command", context do
        context = HarnessHooks.ensure_live_harness(context)
        fake = install_fake_codex(queue: false)
        session = codex_session_id()
        started = start_codex_session(context, session)

        {:ok,
         Map.merge(context, %{
           fake: fake,
           session: session,
           started: started,
           agent_id: started["agent_id"]
         })}
      end

      then_ "the agent was told at join that messages arrive at stop, and why", context do
        said = context.started["hookSpecificOutput"]["additionalContext"]
        assert said =~ "codex queue"
        assert said =~ "when you stop"
        {:ok, context}
      end

      when_ "main messages it", context do
        {:ok, Map.put(context, :sent, message(context, "Check the failing spex."))}
      end

      then_ "the message waits in its inbox, and main is told when it will arrive", context do
        assert {:ok, said} = context.sent
        assert said =~ "when it next stops"
        {:ok, context}
      end

      when_ "the session stops", context do
        {:ok, Map.put(context, :stopped, codex_stop_turn(context, context.session))}
      end

      then_ "the message is handed over at its stop hook", context do
        assert %{"decision" => "block", "reason" => reason} = context.stopped
        assert reason =~ "Check the failing spex."
        {:ok, context}
      end
    end
  end
end
