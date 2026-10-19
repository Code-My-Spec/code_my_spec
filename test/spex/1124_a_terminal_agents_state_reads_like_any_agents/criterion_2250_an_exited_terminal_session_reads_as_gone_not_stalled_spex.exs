defmodule CodeMySpecSpex.Story1124.Criterion2250Spex do
  @moduledoc """
  Story 1124 — A terminal agent's state reads like any agent's.
  Criterion 2250 — An exited terminal session reads as gone, not stalled.
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

  spex "An exited terminal session reads as gone, not stalled", criterion: 2250 do
    scenario "a developer exits Claude Code in the middle of a turn" do
      given_ "a terminal coder whose session is live and busy", context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        started = start_session_on_socket(context, session, inbox.socket)
        assert {:ok, _} = set_role(context, session, "coding")
        submit_prompt(context, session)
        eventually(fn -> assert digest(context) =~ "has not finished" end)

        {:ok,
         Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})}
      end

      when_ "its Claude Code session exits", context do
        close_session(context.session, context.inbox)
        look(context.agent_id)
        {:ok, context}
      end

      then_ "it reads as gone, and is not reported as stalled", context do
        eventually(fn -> assert panel(context) =~ "Away" end)
        refute digest(context) =~ "has not finished"
        refute digest(context) =~ "stalled"
        {:ok, context}
      end

      then_ "its role and its place on the project are unchanged", context do
        assert [%{"id" => id, "role" => "coding"}] = agents(context)
        assert id == context.agent_id
        {:ok, context}
      end
    end
  end
end
