defmodule CodeMySpecSpex.Story1062.Criterion2091Spex do
  @moduledoc "Story 1062: verification reports agreement and measurement failure honestly."
  use CodeMySpecSpex.Case
  import Phoenix.LiveViewTest
  alias CodeMySpecSpex.Fixtures.GraphVerification, as: GraphVerificationFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  @endpoint CodeMySpecWeb.Endpoint

  spex "A failed drain remains visibly failed", criterion: 2091 do
    scenario "the engineer checks graph verification" do
      given_ "a settled event projection", context do
        :ok = GraphVerificationFixtures.seed(context.scope)
        {:ok, context}
      end

      when_ "the engineer opens the verification page", context do
        :ok = GraphVerificationFixtures.fail_drain(context.scope)
        {:ok, view, _html} = live(context.conn, "/dev/graph")

        # DevGraphLive defaults its picker to `List.first(projects)` across
        # every account (it's a cross-account dev tool) -- selecting this
        # test's own project explicitly is what an engineer checking a
        # specific project would actually do, and makes this assertion
        # independent of how many other projects happen to exist.
        html =
          view
          |> element("#dev-graph-project-form")
          |> render_change(%{"project" => context.scope.active_project_id})

        {:ok, Map.put(context, :verification_html, html)}
      end

      then_ "the report describes what was verified", context do
        html = context.verification_html
        assert html =~ "Failed — partial cost"
        assert html =~ "handled mark/checkouts unknown"
        assert html =~ "fallback mark/checkouts unknown"
        {:ok, context}
      end
    end
  end
end
