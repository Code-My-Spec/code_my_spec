defmodule CodeMySpecSpex.Story1092.Criterion2030Spex do
  @moduledoc """
  Story 1092 -- I can see how my in-app agents perform.
  Criterion 2030 -- The chart defaults to the last 7 days in hourly
  buckets.
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

  spex "With no range chosen, the chart defaults to the last 7 days in hourly buckets",
    criterion: 2030 do
    scenario "the performance page is opened with no filters" do
      given_ "a project with the performance page available", context do
        # given: already true — `setup :setup_active_project` creates it.
        {:ok, context}
      end

      when_ "I look at the performance page", context do
        {:ok, index, _html} = live(context.conn, index_path(context))
        html = render_async(index)
        {:ok, Map.put(context, :html, html)}
      end

      then_ "the chart's default range is the last 7 days", context do
        assert context.html =~ "range_days",
               "the chart carries no range-days metadata"

        assert Regex.match?(~r/range_days\D{0,10}7/, context.html),
               "the chart's default range is not 7 days"

        {:ok, context}
      end

      then_ "and its buckets are hourly", context do
        assert context.html =~ "bucket_interval",
               "the chart carries no bucket-interval metadata"

        assert context.html =~ "hour",
               "the chart's default bucket interval is not hourly"

        assert Regex.match?(~r/bucket_count\D{0,10}168/, context.html),
               "7 days in hourly buckets is not 168 buckets"

        {:ok, context}
      end
    end
  end
end
