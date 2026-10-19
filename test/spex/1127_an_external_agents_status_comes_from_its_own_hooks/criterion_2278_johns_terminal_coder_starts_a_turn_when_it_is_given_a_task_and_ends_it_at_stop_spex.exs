defmodule CodeMySpecSpex.Story1127.Criterion2278Spex do
  @moduledoc """
  Story 1127 — An external agent's status comes from its own hooks.
  Criterion 2278 — John's terminal coder starts a turn when it is given a task and ends it at stop.
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

  spex "A terminal coder's turn opens at its prompt and closes at its stop", criterion: 2278 do
    scenario "main gives the coder a task, its session submits the prompt, then it stops" do
      given_ "John's terminal coder is idle in the cockpit", context do
        context = a_terminal_agent(context, "coding")
        {_view, html} = cockpit(context)
        refute html =~ ~s(data-test="team-agent-turn")
        {:ok, context}
      end

      when_ "main messages it a task and its session submits the prompt", context do
        {:ok, _} =
          ToolLibrary.run(
            "message_agent",
            %{"agent_id" => context.agent_id, "message" => "Take the reservations task."},
            %{scope: context.scope}
          )

        hook(context, "user-prompt-submit", %{"prompt" => "Take the reservations task."})
        {:ok, context}
      end

      then_ "the cockpit shows the coder mid-turn", context do
        eventually(fn ->
          {_view, html} = cockpit(context)
          assert html =~ ~s(data-test="team-agent-turn")
        end)

        {:ok, context}
      end

      when_ "the coder's stop hook fires", context do
        hook(context, "stop")
        {:ok, context}
      end

      then_ "the cockpit shows the coder idle and running", context do
        eventually(fn ->
          {_view, html} = cockpit(context)
          refute html =~ ~s(data-test="team-agent-turn")
        end)

        refute liveness_panel(context) =~ "Away"
        assert digest(context) =~ "no turn is open"
        {:ok, context}
      end
    end
  end
end
