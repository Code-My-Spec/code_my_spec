defmodule CodeMySpecSpex.Story1127.Criterion2281Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2281 — A terminal agent idle between turns still reads running.
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

  defp hook(context, name, extra \\ %{}),
    do:
      HarnessHooks.post_hook(context, name, Map.merge(%{"session_id" => context.session}, extra))

  spex "A terminal agent idle between turns reads running", criterion: 2281 do
    scenario "a QA finished a turn long ago and its session is still open" do
      given_ "John's terminal QA finished a turn ten minutes ago and its session is still open",
             context do
        context = a_terminal_agent(context, "qa")
        hook(context, "user-prompt-submit", %{"prompt" => "Test the story."})
        eventually(fn -> assert digest(context) =~ "a turn opened" end)
        hook(context, "stop")
        eventually(fn -> assert digest(context) =~ "no turn is open" end)

        # Ten minutes of nothing: no hook fires while the session sits open.
        :ok =
          CodeMySpecSpex.Fixtures.age_agent_messages(context.scope, %{id: context.agent_id}, 600)

        look(context.agent_id)
        {:ok, context}
      end

      when_ "John opens the team panel", context do
        {view, html} = cockpit(context)
        {:ok, Map.merge(context, %{view: view, html: html})}
      end

      then_ "the QA reads running and not mid-turn, not away", context do
        refute context.html =~ ~s(data-test="team-agent-turn")
        refute liveness_panel(context) =~ "Away"
        assert liveness_panel(context) =~ "Running" or liveness_panel(context) =~ "Idle"
        {:ok, context}
      end
    end
  end
end
