defmodule CodeMySpecSpex.Story1127.Criterion2284Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2284 — A terminal agent running with hooks disabled reads idle.
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
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

    # The team panel is a drawer; John opens it to see his agents.
    render_hook(view, "viewport", %{"width" => 1200})
    html = render(view)

    html =
      if html =~ ~r/data-test="panel-activity"[^>]*data-panel-open="true"/,
        do: html,
        else: render_hook(view, "toggle_panel", %{"panel" => "activity"})

    {view, html}
  end

  spex "A terminal agent with hooks disabled reads idle", criterion: 2284 do
    scenario "the session works a task and fires no hook" do
      given_ "John starts a Claude Code session with hooks disabled in a served checkout, registered as an agent",
             context do
        context = HarnessHooks.ensure_live_harness(context)
        inbox = open_inbox()
        session = session_id()
        # Registered by the one hook that still reached the server, then silent:
        # no prompt, tool or stop hook fires from here.
        started = start_session_on_socket(context, session, inbox.socket)
        assert {:ok, _} = set_role(context, session, "coding")

        {:ok,
         Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})}
      end

      when_ "it works through a task", context do
        # Claude Code itself lists the session busy; the product must not read that.
        session_is(context.session, "busy")
        look(context.agent_id)
        {:ok, context}
      end

      then_ "the cockpit shows it idle, never mid-turn", context do
        {_view, html} = cockpit(context)
        refute html =~ ~s(data-test="team-agent-turn")
        refute digest(context) =~ "has not finished"
        {:ok, context}
      end
    end
  end
end
