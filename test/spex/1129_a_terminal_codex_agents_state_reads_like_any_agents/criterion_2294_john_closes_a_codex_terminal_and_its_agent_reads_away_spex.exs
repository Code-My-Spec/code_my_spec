defmodule CodeMySpecSpex.Story1129.Criterion2294Spex do
  @moduledoc """
  Story 1129 — A terminal Codex agent's state reads like any agent's.
  Criterion 2294 — John closes a Codex terminal and its agent reads away.
  """
  use CodeMySpecSpex.Case

  import CodeMySpecSpex.TerminalAgentHelpers, only: [agents: 1, set_role: 3]
  import CodeMySpecSpex.TerminalCodexHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.HarnessHooks
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
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

  spex "John closes a Codex terminal and its agent reads away", criterion: 2294 do
    scenario "the session ends" do
      given_ "John's terminal Codex coder is listed as running", context do
        context = a_codex_coder(context)
        eventually(fn -> refute liveness_panel(context) =~ "Away" end)
        {:ok, context}
      end

      when_ "John closes its terminal and the session ends", context do
        codex_session_end(context, context.session)
        {:ok, context}
      end

      then_ "the cockpit shows the coder away, not stalled", context do
        eventually(fn -> assert liveness_panel(context) =~ "Away" end)
        {_view, html} = cockpit(context)
        refute html =~ ~s(data-test="team-agent-turn")
        {:ok, context}
      end

      then_ "it stays listed", context do
        assert Enum.any?(agents(context), &(&1["id"] == context.agent_id))
        {:ok, context}
      end
    end
  end
end
