defmodule CodeMySpecSpex.Story1014.Criterion2383Spex do
  @moduledoc """
  Story 1014 — Criterion 2383 — Coming back is onboarding, not recovery.

  Rule: An agent that comes back rebuilds its own state without being repaired.

  Offboard and onboard are inverses. A returning agent re-syncs its files and
  re-runs its analysis, which is the same thing it does on any ordinary hook —
  there is no repair step, no reconciliation, nothing that knows it was ever away.

  Measured cost of coming back: a full re-sync at 663ms for 2000 files, in story
  727's own notes. Cheap enough that reclaiming aggressively is the safe
  direction.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Returning rebuilds rather than repairs" do
    scenario "Coming back is onboarding, not recovery" do
      given_ :synced_context_component

      given_ "the checkout goes quiet and its state is reclaimed", context do
        returning = context.scope
        Fixtures.go_quiet(returning.active_harness_id, 96)

        live = Fixtures.live_agent_scope(context.scope)

        post_hook(live, "/api/hooks/stop", %{
          "session_id" => "spex-#{System.unique_integer([:positive])}"
        })

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "the premise failed: nothing was reclaimed, so there is nothing to " <>
                 "rebuild"

        {:ok, Map.put(context, :returning, returning)}
      end

      when_ "the agent comes back and does the ordinary thing", context do
        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live |> element("button[phx-click='sync']") |> render_click()

        {:ok, context}
      end

      then_ "its component is back, with no repair step anywhere", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        assert render(view) =~ "ExampleContext",
               "a returning agent did not rebuild what was reclaimed. The working " <>
                 "copy is the truth, so an ordinary sync is all it should take — if " <>
                 "returning needs a repair path, offboard and onboard are not " <>
                 "inverses and every absence leaves something for a human to fix."

        {:ok, context}
      end
    end
  end
end
