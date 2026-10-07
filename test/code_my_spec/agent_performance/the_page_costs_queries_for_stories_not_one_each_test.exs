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

  The fixtures include agents with operator and tool messages, because the
  first version of this test did not: it matched no messages at all, so the
  read's `select` was never exercised and the page raised `KeyError
  :agent_id` on every real project (issue 74bf255e) while this test stayed
  green. A read of zero rows proves nothing about the rows that do come back.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.AgentPerformanceHelpers

  alias CodeMySpec.AgentPerformance
  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpecSpex.Fixtures
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
    agents(context)
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
    agents(context)

    page = AgentPerformance.page(context.scope)

    assert Enum.count(page.stories) == @large,
           "the batched read dropped stories from the page"

    assert Map.has_key?(page.reports, hd(page.stories).id),
           "a story the page lists has no report beside it"

    assert Map.has_key?(page, :agents),
           "the page's read dropped the agents its filter needs"
  end

  # The read that raised on real data (`KeyError :agent_id`, issue 74bf255e)
  # did so only when a message matched. This drives `load/1` with agents
  # holding operator and tool messages in their transcripts, through the same
  # private read the page mounts on, and asserts the report they feed comes
  # back populated -- zero matched rows is what let the crash through.
  test "the page's read survives agents with messages in their transcripts", context do
    with_stories(context, @small, 0)
    {agent, restart} = agents(context)

    page = AgentPerformance.page(context.scope)

    row = Enum.find(page.summary.agents, &(&1.agent_id == agent.id))

    assert row, "the agent with messages has no row on the page"
    assert row.tool_failures.total_calls == 2, "the agent's tool messages were not read"
    assert row.tool_failures.failed_calls == 1, "a failed tool call was not counted as failed"

    # The restart is an operator message at the agent holding a story, so it
    # has to show up as an intervention against that story rather than nowhere.
    story_id = agent.story_id

    assert Enum.any?(page.reports[story_id].interventions, &(&1.kind == :restart)),
           "the operator message was read but did not reach the story it served"

    assert Enum.any?(page.reports[story_id].interventions, &(&1.reason =~ restart)),
           "the intervention does not name why the agent was restarted"
  end

  # The index is still reachable -- a batched read that answers in fewer queries
  # but takes the page's route down with it is not a fix.
  test "the index still renders and both filters are reachable", context do
    with_stories(context, @small, 0)
    agents(context)

    {:ok, index, html} = live(context.conn, index_path(context))

    assert html =~ "performance-filter", "the filter form is gone from the page"
    assert html =~ "agent_id", "the agent filter is gone from the page"
    assert render(index) =~ "Performance story #{@small}", "the page dropped a story"
  end

  # The fixtures the first version of this test lacked: agents holding a story,
  # each with a transcript the page's `agent_messages/1` actually returns.
  # The agent takes its story the way the app does -- `Assignment`'s own claim
  # -- rather than by writing `story_id` behind its back.
  defp agents(context) do
    agent = Fixtures.running_agent(context.scope, role: "coding", working_copy: "/tmp/perf-page")
    story_id = hd(page(context).stories).id

    :ok = Agents.claim_story(context.scope, agent, story_id)

    conversation = conversation_for(context, agent)
    reason = "the copy stopped answering"

    {:ok, _} = Conversations.add_message(conversation, :operator, reason, "system:restart")

    {:ok, _} =
      Conversations.add_tool_result(conversation, "call-1", "read_file", "read_file -> ok")

    {:ok, _} =
      Conversations.add_tool_result(conversation, "call-2", "compile", "compile -> failed",
        failed?: true
      )

    {:ok, held} = Agents.fetch_agent(context.scope, agent.id)
    {held, reason}
  end

  defp page(context), do: AgentPerformance.page(context.scope)

  defp conversation_for(context, agent) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    conversation
  end

  defp with_stories(context, count, offset) do
    Enum.each(1..count, fn i ->
      n = offset + i

      {:ok, story} =
        Stories.create_story(context.scope, %{
          title: "Performance story #{n}",
          description: "A story the performance page must report on (#{n})."
        })

      # Ready for development, so an agent can take it the way the app takes a
      # story rather than by writing the column behind the claim's back.
      {:ok, _story} =
        story |> Story.changeset(%{ready_for_dev: true}) |> Repo.update()
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
