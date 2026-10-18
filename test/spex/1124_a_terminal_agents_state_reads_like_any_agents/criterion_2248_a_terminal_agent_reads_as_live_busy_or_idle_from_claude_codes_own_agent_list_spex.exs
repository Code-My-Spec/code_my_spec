defmodule CodeMySpecSpex.Story1124.Criterion2248Spex do
  @moduledoc """
  Story 1124 — A terminal agent's state reads like any agent's.
  Criterion 2248 — A terminal agent reads as live, busy or idle from Claude Code's own agent list.
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

  defp panel(context) do
    {:ok, _view, html} =
      live(
        context.conn,
        "/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
      )

    html
  end

  spex "A terminal agent reads as live, busy or idle from Claude Code's own agent list",
    criterion: 2248 do
    scenario "the harness reads the session from claude agents on its machine" do
      given_ "a registered terminal agent whose session is live and idle", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        started = start_session_on_socket(context, session, inbox.socket)

        {:ok,
         Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})}
      end

      then_ "main and the person see it live and idle", context do
        eventually(fn -> assert panel(context) =~ "Running" end)
        assert digest(context) =~ "no turn is open"
        {:ok, context}
      end

      when_ "Claude Code lists its session as busy", context do
        session_is(context.session, "busy")
        look(context.agent_id)
        {:ok, context}
      end

      then_ "main sees it busy, like any agent with a turn open", context do
        eventually(fn -> assert digest(context) =~ "has not finished" end)
        {:ok, context}
      end

      when_ "Claude Code lists its session as idle again", context do
        session_is(context.session, "idle")
        look(context.agent_id)
        {:ok, context}
      end

      then_ "main sees it idle", context do
        eventually(fn -> assert digest(context) =~ "no turn is open" end)
        {:ok, context}
      end
    end
  end
end
