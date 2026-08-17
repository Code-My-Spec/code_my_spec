defmodule CodeMySpecSpex.Story1014.Criterion2382Spex do
  @moduledoc """
  Story 1014 — Criterion 2382 — Idle time does not depend on the machine's
  timezone.

  Rule: Times are compared in UTC, without a workaround at the comparison.

  `harnesses.updated_at` is `timestamp without time zone` holding UTC, while
  `now()` is timestamptz. Compared naively, Postgres renders `now()` in local time
  and every live agent reads as −4 hours idle. The first measurement taken for
  this story said exactly that, and an expiry written the obvious way would never
  fire here and would fire wrongly in another zone or after a DST change.

  `last_seen_at` is `utc_datetime_usec`, so keying liveness on it makes the
  comparison correct by construction rather than by care. This pins that choice: a
  later change back to `updated_at` fails here rather than silently reclaiming
  nothing.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecLocalWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Idle is measured in UTC" do
    scenario "Idle time does not depend on the machine's timezone" do
      given_ :synced_context_component

      given_ "a checkout quiet by hours, not by days", context do
        # Just past a 2h window. A comparison that renders one side in local time
        # is wrong by whole hours, so a margin this small fails loudly there and
        # passes cleanly under a correct one.
        Fixtures.all_agents_go_quiet(context.scope, 2.5)
        {:ok, context}
      end

      given_ "another agent is working", context do
        {:ok, Map.put(context, :live, Fixtures.live_agent_scope(context.scope))}
      end

      when_ "the live agent stops, which syncs components", context do
        post_hook(context.live, "/api/hooks/stop", %{
          "session_id" => "spex-#{System.unique_integer([:positive])}"
        })

        {:ok, context}
      end

      then_ "the checkout is judged quiet and reclaimed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/components")

        refute render(view) =~ "ExampleContext",
               "a checkout 2.5 hours idle was not reclaimed under a 2 hour window. " <>
                 "A few hours' error is the signature of comparing a naive UTC " <>
                 "timestamp against a zoned `now()` — it reads every live agent as " <>
                 "hours in the future here, and would reclaim live agents in another " <>
                 "zone. Key liveness on `last_seen_at`, which is utc_datetime_usec."

        {:ok, context}
      end
    end
  end
end
