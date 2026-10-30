defmodule CodeMySpecSpex.Story1092.Criterion2029Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2029 -- The performance page charts token spend, nudges and
  failed turns over time, and shows QA attempts passed against failed.

  QA came off the time chart: an hourly rate was mostly empty hours, so it is
  a ring of attempts by outcome (John, 2026-10-14). This checks the chart
  carries the three series and the page carries the ring -- whether any one
  metric's own number is correct is covered by the criteria that introduced
  it (1979, 2008/2009, 2005, 2010).
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

  spex "The performance page's chart carries token spend, messages and failed turns, and QA as passed against failed",
    criterion: 2029 do
    scenario "the performance page is opened" do
      given_ "a project with the performance page available", context do
        # given: already true — `setup :setup_active_project` creates it.
        {:ok, context}
      end

      when_ "I look at the performance page", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = await_report(index)
        series = chart_data(index, "#performance-chart")["series"] |> Enum.map(& &1["name"])
        {:ok, context |> Map.put(:html, html) |> Map.put(:series, series)}
      end

      then_ "the chart carries a time series for token spend", context do
        assert context.html =~ "token_spend",
               "the chart does not carry a token-spend series"

        {:ok, context}
      end

      then_ "and for messages sent to agents", context do
        assert "messages" in context.series,
               "the chart does not carry a messages series"

        {:ok, context}
      end

      then_ "and QA attempts are shown as passed against failed, not as a line", context do
        assert context.html =~ ~s(data-test="qa-attempts"),
               "the page does not show QA attempts by outcome"

        refute context.html =~ "qa_first_pass_rate",
               "QA first-pass rate is still drawn as a line on the time chart"

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
