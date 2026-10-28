defmodule CodeMySpec.AgentPerformance.ThePageJoinsWithoutWaitingForTheReadTest do
  @moduledoc """
  Story 1092, issue 5d359bb3: the page's *join* must not wait for the report.

  The two earlier fixes on this page (batching the N+1, then the
  `agent_messages/1` select) each moved the wall without getting under it: on
  the real 166-story, 180-agent project `handle_params` still took
  10.4-14.6s, past the Phoenix JS client's 10s `DEFAULT_TIMEOUT`, so the join
  was abandoned, the LiveView sat in `phx-error phx-server-error` and the
  filter form's `phx-change` never fired -- criteria 2050, 2052 and 2053 were
  unreachable in a browser at real scale (QA attempt 3, 30026a2e).

  So this does not measure seconds: a test that asserted "the join took under
  a second" would pass on a fast machine running the code that broke, which is
  how the previous fix on this page stayed green (`KeyError :agent_id`, issue
  74bf255e). It measures the shape instead -- the join's own reads are a
  handful, and do not grow with the project, because the report is behind
  `assign_async/3` in a task rather than in `handle_params`.

  The fixtures deliberately include stories and agents with messages, so the
  frame is built over rows that exist rather than over an empty project. Three
  times the stories and agents must not cost three times the queries: the
  shape that broke is a join that reads the report.
  """

  use CodeMySpecSpex.Case, async: false

  import CodeMySpecSpex.AgentPerformanceHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @small 4
  @large 12

  # The join's cost is the same read for four stories as for twelve. A join
  # that ran the report would scale with both -- the old `handle_params` did,
  # which is what timed the socket out.
  test "the join's cost does not grow with the project", context do
    seed(context, @small, 1)
    small = count_join(context)

    seed(context, @large - @small, @small + 1)
    large = count_join(context)

    ratio = large / small

    assert ratio < 1.3,
           "joining with #{@large} stories and agents took #{large} queries against " <>
             "#{small} with #{@small} (ratio #{Float.round(ratio, 2)}) -- the join's reads " <>
             "still scale with the project, so the report is back in `handle_params` " <>
             "where it timed the 10s socket timeout out on the real project (issue 5d359bb3)."
  end

  # The point of the change: the selects are on the page the moment the join
  # replies, before the report has been read. If this page ever goes back to
  # reading the report inside the join, these options are empty on the initial
  # render and this fails.
  test "the selects are populated on the render the join replies with", context do
    seed(context, @small, 1)

    {:ok, index, html} = live(context.conn, index_path(context))

    for id <- ["filter-working-copy", "filter-story", "filter-agent"] do
      assert html =~ ~s(id="#{id}"), "the #{id} select is not on the page the join replies with"
    end

    assert html =~ "Perf story 1",
           "the story select was empty on the render the join replied with"

    # The report itself has not arrived yet on this render -- that is the whole
    # point of it being async -- and the page says so rather than looking
    # broken.
    assert html =~ "performance-loading", "the page shows no loading state while it reads"

    # ...and then it does arrive, over the same socket, without a reload.
    assert render_settled(index) =~ "Perf story 1"
  end

  # `agent_id` narrows to one agent and the select carries it; the story
  # select the same, on its own param. Neither needs the report to have
  # arrived: the *frame* carries both selects' options, and a patch re-reads
  # the frame.
  test "each select pushes a patch and the page narrows to it", context do
    seed(context, @small, 1)

    {:ok, index, _html} = live(context.conn, index_path(context))

    agent_id = Agents.list_agents(context.scope) |> hd() |> Map.fetch!(:id)

    index
    |> form("[data-test=performance-filter]", %{"agent_id" => agent_id})
    |> render_change()

    assert_patch(index, index_path(context) <> "?agent_id=#{agent_id}")

    html = render(index)
    assert html =~ ~s(value="#{agent_id}" selected), "the agent select does not carry the patch"

    # The story select pushes the same way, on its own param. The form submits
    # all three selects, so the patch carries the agent still selected.
    story_id = Stories.list_story_titles(context.scope) |> hd() |> Map.fetch!(:id)

    index
    |> form("[data-test=performance-filter]", %{"story_id" => to_string(story_id)})
    |> render_change()

    assert_patch(index, index_path(context) <> "?agent_id=#{agent_id}&story_id=#{story_id}")
  end

  # Counts the queries the join makes. Attached for the length of the call and
  # detached after: `Repo` runs in the caller, so this is the join's own reads
  # and not the task's -- which is why the assertion is about the join rather
  # than about the page's whole cost (that is
  # `the_page_costs_queries_for_stories_not_one_each_test.exs`).
  defp count_join(context) do
    handler = "perf-page-join-#{inspect(make_ref())}"
    counter = :counters.new(1, [:atomics])
    owner = self()

    :telemetry.attach(
      handler,
      [:code_my_spec, :repo, :query],
      fn
        _event, _measurements, _meta, _config when self() == owner ->
          :counters.add(counter, 1, 1)

        _event, _measurements, _meta, _config ->
          :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, _index, _html} = live(context.conn, index_path(context))
    :telemetry.detach(handler)

    :counters.get(counter, 1)
  end

  # Stories an agent can take, and agents holding one with a transcript the
  # page's read actually returns -- an empty project proves nothing about the
  # rows that do come back (issue 74bf255e).
  #
  # The count is the number of *stories*, and is what the query bound is about:
  # the old join ran the report over every story. Agents are not per story.
  # One copy's team holds one story at a time -- `Assignment` refuses a second
  # claim onto the same copy, and rightly -- so the fixture advances the team
  # the way the app does: it releases the story it finished and takes the next,
  # on the same copy with the same agents.
  defp seed(context, count, first) do
    copy_id = copy(context)

    first..(first + count - 1)
    |> Enum.each(fn i -> seed_story(context, copy_id, i) end)

    context
  end

  # Agents may join the copy after the first story -- `agent_on/3` creates one
  # only when there is none -- so the agent on the first story is the one whose
  # conversation carries the message. `assign_team/3` has put the story on
  # *every* member by then, and the transcript is per agent, not per story.
  defp seed_story(context, copy_id, i) do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Perf story #{i}",
        description: "A story the performance page reports on (#{i})."
      })

    {:ok, _story} =
      story |> Story.changeset(%{ready_for_dev: true}) |> Repo.update()

    agent = agent_on(context, copy_id, i)
    :ok = take_next(context.scope, copy_id, story.id)

    {:ok, _} =
      Conversations.add_message(
        conversation_for(context, agent),
        :operator,
        "restart #{i}",
        "system:restart"
      )
  end

  # The project's *main* copy, which `setup_active_project` already registered
  # when it selected the project (`WorkingCopies.issue/3` on the stub root).
  # Reusing it matters twice over: the page reads `current_scope`, whose
  # `active_working_copy_id` names this copy, and `Assignment.claim/3` refuses a
  # story the team already holds *outside* the one being claimed -- which is
  # exactly what a second copy in the same project produces.
  defp copy(context) do
    context.scope.active_working_copy_id ||
      WorkingCopies.most_recent(context.scope).id
  end

  # One agent per copy, not per story: a second one joins the same team and
  # inherits the story it is holding.
  defp agent_on(context, copy_id, i) do
    existing_or_running_agent(Agents.list_agents(context.scope), context, copy_id, i)
  end

  defp existing_or_running_agent([agent | _], _context, _copy_id, _i), do: agent

  defp existing_or_running_agent([], context, copy_id, i) do
    Fixtures.running_agent(context.scope,
      role: "coding",
      working_copy: "/tmp/perf-join-#{i}",
      working_copy_id: copy_id
    )
  end

  # Move the team from the story it finished to the next one. `assign_team/3`
  # is the app's own path -- it releases what the team held, reserves the next
  # story and fans both out to every member -- and it is the only path that
  # does not trip `claim/3`'s refusal of a story outside the one now held.
  defp take_next(scope, copy_id, story_id) do
    {:ok, _id} = Agents.assign_team(scope, copy_id, story_id)
    :ok
  end

  defp conversation_for(context, agent) do
    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    conversation
  end
end
