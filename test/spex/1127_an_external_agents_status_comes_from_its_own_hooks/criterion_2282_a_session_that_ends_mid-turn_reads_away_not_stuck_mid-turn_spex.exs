defmodule CodeMySpecSpex.Story1127.Criterion2282Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2282 — A session that ends mid-turn reads away, not stuck mid-turn.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers
  import Phoenix.LiveViewTest

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

  # The cockpit's team panel: the page John watches his agents on.
  defp cockpit(context) do
    {:ok, view, html} =
      live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

    {view, html}
  end

  defp liveness_panel(context) do
    {:ok, _view, html} =
      live(
        context.conn,
        "/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
      )

    html
  end

  # A terminal agent in `role`, whose session is open and whose hooks fire. Its
  # state comes from those hooks alone, so Claude Code's own agent list is left
  # idle throughout.
  defp a_terminal_agent(context, role) do
    context = HarnessHooks.ensure_live_harness(context)
    inbox = open_inbox()
    session = session_id()
    started = start_session_on_socket(context, session, inbox.socket)
    assert {:ok, _} = set_role(context, session, role)
    look(started["agent_id"])

    Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})
  end

  defp hook(context, name, extra),
    do:
      HarnessHooks.post_hook(context, name, Map.merge(%{"session_id" => context.session}, extra))

  spex "A session that ends mid-turn reads away", criterion: 2282 do
    scenario "the session ends without a stop hook" do
      given_ "John's terminal coder is mid-turn", context do
        context = a_terminal_agent(context, "coding")
        hook(context, "user-prompt-submit", %{"prompt" => "Refactor the context."})
        eventually(fn -> assert digest(context) =~ "has not finished" end)
        {:ok, context}
      end

      when_ "its Claude Code session ends without a stop hook", context do
        hook(context, "session-end", %{"reason" => "other"})
        close_session(context.session, context.inbox)
        look(context.agent_id)
        {:ok, context}
      end

      then_ "the cockpit shows the coder away", context do
        eventually(fn -> assert liveness_panel(context) =~ "Away" end)
        {:ok, context}
      end

      then_ "no mid-turn bubble remains", context do
        {_view, html} = cockpit(context)
        refute html =~ ~s(data-test="team-agent-turn")
        refute digest(context) =~ "has not finished"
        {:ok, context}
      end
    end
  end
end
