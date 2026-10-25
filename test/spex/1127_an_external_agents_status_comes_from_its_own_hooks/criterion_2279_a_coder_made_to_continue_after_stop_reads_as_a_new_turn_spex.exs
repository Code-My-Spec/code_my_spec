defmodule CodeMySpecSpex.Story1127.Criterion2279Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2279 — A coder made to continue after stop reads as a new turn.
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

  defp open_activity_panel(_view, html, true), do: html

  defp open_activity_panel(view, _html, false),
    do: render_hook(view, "toggle_panel", %{"panel" => "activity"})

  # The cockpit's team panel: the page John watches his agents on.
  defp cockpit(context) do
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/agent-conversation")

    # The team panel is a drawer; John opens it to see his agents.
    render_hook(view, "viewport", %{"width" => 1200})
    html = render(view)

    html =
      open_activity_panel(
        view,
        html,
        html =~ ~r/data-test="panel-activity"[^>]*data-panel-open="true"/
      )

    {view, html}
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
    await_present(context, started["agent_id"])
    look(started["agent_id"])

    Map.merge(context, %{inbox: inbox, session: session, agent_id: started["agent_id"]})
  end

  defp hook(context, name, extra \\ %{}),
    do:
      HarnessHooks.post_hook(context, name, Map.merge(%{"session_id" => context.session}, extra))

  spex "A coder that continues after stop opens a new turn", criterion: 2279 do
    scenario "the harness hands it another message after it has stopped" do
      given_ "John's terminal coder has just stopped and reads idle", context do
        context = a_terminal_agent(context, "coding")
        hook(context, "user-prompt-submit", %{"prompt" => "First task."})
        eventually(fn -> assert digest(context) =~ "a turn opened" end)
        hook(context, "stop")
        eventually(fn -> assert digest(context) =~ "no turn is open" end)
        {:ok, context}
      end

      when_ "the harness hands it another message so it continues", context do
        {:ok, _} =
          ToolLibrary.run(
            "message_agent",
            %{"agent_id" => context.agent_id, "message" => "One more thing."},
            %{scope: context.scope}
          )

        hook(context, "user-prompt-submit", %{"prompt" => "One more thing."})
        {:ok, context}
      end

      then_ "the cockpit shows a new turn starting for the coder", context do
        eventually(fn ->
          {_view, html} = cockpit(context)
          assert html =~ ~s(data-test="team-agent-turn")
        end)

        {:ok, context}
      end

      then_ "the previous turn stays closed", context do
        # One turn is open, the new one; ending it leaves nothing open, so the
        # first turn did not stay open beneath it.
        hook(context, "stop", %{})
        eventually(fn -> assert digest(context) =~ "no turn is open" end)
        {:ok, context}
      end
    end
  end
end
