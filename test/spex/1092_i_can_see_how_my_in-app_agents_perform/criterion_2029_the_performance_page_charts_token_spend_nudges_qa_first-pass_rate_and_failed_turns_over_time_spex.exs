defmodule CodeMySpecSpex.Story1092.Criterion2029Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2029 -- The performance page charts token spend, nudges, QA
  first-pass rate and failed turns over time.

  This checks the chart carries all four metrics as its series -- whether
  any one metric's own number is correct is covered by the criteria that
  introduced that metric (1979, 2008/2009, 2005, 2010).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.AgentPerformanceHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "The performance page's chart carries token spend, nudges, QA first-pass rate and failed turns",
    criterion: 2029 do
    scenario "the performance page is opened" do
      given_ "a project with the performance page available", context do
        # given: already true — `setup :setup_active_project` creates it.
        {:ok, context}
      end

      when_ "I look at the performance page", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart carries a time series for token spend", context do
        assert context.html =~ "token_spend",
               "the chart does not carry a token-spend series"

        {:ok, context}
      end

      then_ "and for nudges", context do
        assert context.html =~ "nudges",
               "the chart does not carry a nudges series"

        {:ok, context}
      end

      then_ "and for QA first-pass rate", context do
        assert context.html =~ "qa_first_pass_rate",
               "the chart does not carry a QA first-pass-rate series"

        {:ok, context}
      end

      then_ "and for failed turns", context do
        assert context.html =~ "failed_turns",
               "the chart does not carry a failed-turns series"

        {:ok, context}
      end
    end
  end
end
