defmodule CodeMySpecSpex.Story1129.Criterion2291Spex do
  @moduledoc """
  Story 1129 — A terminal Codex agent's state reads like any agent's.
  Criterion 2291 — John's Codex coder shows mid-turn while it works and idle at stop.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers, only: [set_role: 3]
  import CodeMySpecSpex.TerminalCodexHelpers
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
      open_activity_panel(
        view,
        html,
        html =~ ~r/data-test="panel-activity"[^>]*data-panel-open="true"/
      )

    {view, html}
  end

  defp open_activity_panel(_view, html, true), do: html

  defp open_activity_panel(view, _html, false),
    do: render_hook(view, "toggle_panel", %{"panel" => "activity"})

  defp liveness_panel(context) do
    {:ok, _view, html} =
      live(
        context.conn,
        "/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
      )

    html
  end

  # A Codex coder whose session is open and whose hooks fire; its rollout is
  # where Codex writes what it says and spends.
  defp a_codex_coder(context) do
    context = HarnessHooks.ensure_live_harness(context)
    session = codex_session_id()
    rollout = codex_rollout_for(session)
    started = start_codex_session(context, session, %{"transcript_path" => rollout})
    assert {:ok, _} = set_role(context, session, "coding")

    Map.merge(context, %{session: session, rollout: rollout, agent_id: started["agent_id"]})
  end

  spex "John's Codex coder shows mid-turn while it works and idle at its stop",
    criterion: 2291 do
    scenario "the coder's session submits a prompt and then stops" do
      given_ "John's terminal Codex coder is idle", context do
        context = a_codex_coder(context)
        {_view, html} = cockpit(context)
        refute html =~ ~s(data-test="team-agent-turn")
        {:ok, context}
      end

      when_ "it is given a task and its session submits the prompt", context do
        codex_submit_prompt(context, context.session)
        {:ok, context}
      end

      then_ "the cockpit shows it mid-turn", context do
        eventually(fn ->
          {_view, html} = cockpit(context)
          assert html =~ ~s(data-test="team-agent-turn")
        end)

        {:ok, context}
      end

      when_ "its stop hook fires", context do
        codex_stop_turn(context, context.session)
        {:ok, context}
      end

      then_ "the cockpit shows it idle and running", context do
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
