defmodule CodeMySpecSpex.Story1062.Criterion2089Spex do
  @moduledoc "Story 1062: verification reports agreement and measurement failure honestly."
  use CodeMySpecSpex.Case
  import Phoenix.LiveViewTest
  alias CodeMySpecSpex.Fixtures.GraphVerification, as: GraphVerificationFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  @endpoint CodeMySpecWeb.Endpoint

  spex "Equivalent graphs report agreement", criterion: 2089 do
    scenario "the engineer checks graph verification" do
      given_ "a settled event projection", context do
        :ok = GraphVerificationFixtures.seed(context.scope)
        {:ok, context}
      end

      when_ "the engineer opens the verification page", context do
        {:ok, _view, html} = live(context.conn, "/dev/graph")
        {:ok, Map.put(context, :verification_html, html)}
      end

      then_ "the report describes what was verified", context do
        html = context.verification_html
        assert html =~ "agree with the rows being served"
        refute html =~ "graph differs from what is served"
        {:ok, context}
      end
    end
  end
end
