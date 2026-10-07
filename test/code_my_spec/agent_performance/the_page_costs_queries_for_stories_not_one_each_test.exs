defmodule CodeMySpec.AgentPerformance.ThePageCostsQueriesForStoriesNotOneEachTest do
  @moduledoc """
  Story 1092, issue 844907e0: the performance page costs a handful of queries
  whatever the project's size.

  QA found the page's LiveView join never completed on a real project (166
  stories, 180 agents): `AgentPerformanceLive.Index.load/1` called
  `AgentPerformance.story_report/2` and `team_first_pass_rate/3` per story and
  per team, each of which re-read the project's sessions, agents, attempts and
  turns -- ~13,000 queries, ~21s to render, and a join that timed out before
  the chart or the filter form could be reached.

  The page is driven through `AgentPerformance.page/1` here, which is what
  `Index.load/1` now reads: mounting the LiveView would also charge the test
  for the assigns and the har's own reads, and the N+1 this bounds lived in the
  page's data read.

  A test that pinned an exact number would pass on the code that broke. The
  assertion is that the cost does not scale with the number of stories: the
  same read over four times as many stories must not cost anywhere near four
  times as many queries. A per-story read -- the shape that broke -- lands near
  4x; the batched read stays flat.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.AgentPerformanceHelpers

  alias CodeMySpec.AgentPerformance
  alias CodeMySpec.Stories
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # Enough stories that a per-story read is unmistakable, small enough to build
  # in a test. At this size the old path ran ~6-8 queries per story.
  @small 6
  @large 24

  test "the page's read cost does not grow with the number of stories", context do
    with_stories(context, @small, 0)
    small = count_page_load(context)

    with_stories(context, @large - @small, @small)
    large = count_page_load(context)

    ratio = large / small

    # Four times the stories must not cost meaningfully more queries. Measured
    # before the batching: 273 -> 525 at this size, a ratio of 1.92 -- a
    # per-story read, as QA found. Batched it is flat. The bound sits well
    # clear of both, so it fails the shape that broke and leaves the batching
    # room to vary.
    assert ratio < 1.3,
           "loading #{@large} stories took #{large} queries against #{small} for " <>
             "#{@small} (ratio #{Float.round(ratio, 2)}) -- the page's read still scales " <>
             "with the project's size. A per-story read (~6-8 queries each) is the N+1 " <>
             "QA measured as ~13,000."
  end

  test "the page still reports every story", context do
    with_stories(context, @large, 0)

    page = AgentPerformance.page(context.scope)

    assert Enum.count(page.stories) == @large,
           "the batched read dropped stories from the page"

    assert Map.has_key?(page.reports, hd(page.stories).id),
           "a story the page lists has no report beside it"

    assert Map.has_key?(page, :agents),
           "the page's read dropped the agents its filter needs"
  end

  # The index is still reachable -- a batched read that answers in fewer queries
  # but takes the page's route down with it is not a fix.
  test "the index still renders and both filters are reachable", context do
    with_stories(context, @small, 0)

    {:ok, index, html} = live(context.conn, index_path(context))

    assert html =~ "performance-filter", "the filter form is gone from the page"
    assert html =~ "agent_id", "the agent filter is gone from the page"
    assert render(index) =~ "Performance story #{@small}", "the page dropped a story"
  end

  defp with_stories(context, count, offset) do
    Enum.each(1..count, fn i ->
      n = offset + i

      {:ok, _story} =
        Stories.create_story(context.scope, %{
          title: "Performance story #{n}",
          description: "A story the performance page must report on (#{n})."
        })
    end)

    context
  end

  # Counts the queries the page's own read makes. Attached for the length of
  # the call and detached after: `Repo` runs in the caller, so the count is this
  # read alone while the rest of the suite runs alongside.
  defp count_page_load(context) do
    handler = "perf-page-queries-#{inspect(make_ref())}"
    counter = :counters.new(1, [:atomics])
    owner = self()

    :telemetry.attach(
      handler,
      [:code_my_spec, :repo, :query],
      fn _event, _measurements, _meta, _config ->
        if self() == owner, do: :counters.add(counter, 1, 1)
      end,
      nil
    )

    try do
      AgentPerformance.page(context.scope)
    after
      :telemetry.detach(handler)
    end

    :counters.get(counter, 1)
  end
end
