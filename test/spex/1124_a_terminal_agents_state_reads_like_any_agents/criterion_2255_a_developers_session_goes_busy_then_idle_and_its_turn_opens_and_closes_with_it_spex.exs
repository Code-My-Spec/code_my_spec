defmodule CodeMySpecSpex.Story1124.Criterion2255Spex do
  @moduledoc """
  Story 1124 — A terminal agent's state reads like any agent's.
  Criterion 2255 — A developer's session goes busy, then idle, and its turn opens and closes with it.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers

  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  defp digest(context) do
    {:ok, work} = ToolLibrary.run("list_agent_work", %{}, %{scope: context.scope})
    work
  end

  spex "A terminal agent's turns follow Claude Code's own agent list", criterion: 2255 do
    scenario "the session goes busy, then idle" do
      given_ "a registered terminal agent whose session is live and idle", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        started = start_session_on_socket(context, session, inbox.socket)

        {:ok,
         Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})}
      end

      when_ "Claude Code lists the session busy", context do
        session_is(context.session, "busy")
        look(context.agent_id)
        {:ok, context}
      end

      then_ "a turn is open for it", context do
        eventually(fn -> assert digest(context) =~ "a turn opened" end)
        {:ok, context}
      end

      when_ "Claude Code lists the session idle", context do
        session_is(context.session, "idle")
        look(context.agent_id)
        {:ok, context}
      end

      then_ "its turn has ended", context do
        eventually(fn -> assert digest(context) =~ "no turn is open" end)
        {:ok, context}
      end
    end
  end
end
