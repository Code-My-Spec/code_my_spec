defmodule CodeMySpecSpex.Story1062.Criterion3520Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3520 — A mark survives the restart of whatever was going to apply
  it.

  Rule: the claim that an entity is out of date outlives the process that has
  to act on it.

  ## Why durable and not a dirty set in memory

  An accumulated dirty set is the obvious implementation and it is wrong here
  for one reason: the process holding it is the process that applies it, so
  anything that kills the applier also erases the record of what it was going
  to do. The graph is then permanently stale in exactly the entities that were
  mid-flight, with nothing anywhere saying so — and the next read serves those
  answers confidently, because from the rows' point of view they were computed
  normally.

  A derived dirty set does not have this problem: it can be recomputed from the
  inputs. An *accumulated* one cannot, which is why the marks are rows.

  ## What this costs, and why that is the trade

  A queue nobody could see. On 2026-09-17 the projector raised on every drain
  for twenty minutes, the backlog grew from 31 marks to 610, and the only
  symptom visible from outside was that nothing changed. That is the bill for
  durability, and the graph dev page is where it is paid — which is why this
  criterion is observed there rather than by counting rows.

  ## Surface

  The graph dev page's backlog panel. The claim is "the marks are still there",
  and "there" has to mean somewhere a person can look, or the durability is as
  invisible as the failure it prevents.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :project_the_marks

  @endpoint CodeMySpecWeb.Endpoint

  # Restores the projector setting however the scenario leaves it.
  #
  # The scenario turns it on part-way through, and that ordering is forced: the
  # projector is eager, so an observation made while it is up is drained before
  # anything can look at it. Recording with it down is the only way to hold the
  # "recorded but not yet applied" state this criterion starts from — and it is
  # also exactly the state a restart recovers from.
  #
  # Off by default outside dev, which means nothing applies marks at all there.
  # That is a real gap, filed as `e0729ea9`, and is not this criterion's
  # subject.
  defp project_the_marks(_context) do
    previous = Application.get_env(:code_my_spec, :graph_shadow_projection, false)
    on_exit(fn -> Application.put_env(:code_my_spec, :graph_shadow_projection, previous) end)
    :ok
  end

  spex "Marks outlive the process that applies them", criterion: 1428 do
    scenario "the applier is stopped between the observation and the drain" do
      given_ :synced_context_component

      given_ "a settled graph and a story to file against", context do
        _settled = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)

        story =
          create_story(context.scope,
            title: "The story the issue is about",
            description: "so the observation names something"
          )

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      given_ "an observation recorded but not yet applied", context do
        # Stopped first, so the mark lands with nothing running to drain it.
        # This is the state the rule is about and it is otherwise very hard to
        # hold still: the watcher is eager, and an observation made while it is
        # up is usually gone before anything can look.
        Fixtures.stop_graph_watchers()

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "recorded while nothing was running to apply it",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)

        {:ok, Map.put(context, :pending_before, pending(context))}
      end

      when_ "the process that applies them is restarted", context do
        Fixtures.stop_graph_watchers()
        Application.put_env(:code_my_spec, :graph_shadow_projection, true)
        Fixtures.watch_graph(context.scope)

        {:ok, Map.put(context, :pending_after, pending(context))}
      end

      then_ "the marks are still there with nothing running to apply them", context do
        assert context.pending_before > 0,
               """
               Nothing was queued while the applier was stopped.

               This is the durability claim, and it is observed from a page
               render — a different process, reading rows — rather than from
               anything holding the marks in memory. An empty answer here means
               either the writer said nothing, or the record of what it said
               lived only in the process that has now been stopped. The second
               is the failure this rule exists to rule out: entities
               permanently out of date, with nothing anywhere recording that
               they are.
               """

        {:ok, context}
      end

      then_ "and they are applied after the restart rather than lost", context do
        assert context.pending_after < context.pending_before,
               """
               #{context.pending_before} mark(s) outlived the stopped applier and
               #{context.pending_after} were still queued after it came back.

               Surviving is only half the rule. A mark that outlives its applier
               and is never picked up afterwards has turned a lost update into a
               stuck queue — the 610-mark backlog of 2026-09-17, where nothing
               was lost and nothing moved either.

               queued while stopped: #{context.pending_before}
               after the restart:    #{context.pending_after}
               """

        {:ok, context}
      end
    end
  end

  # What the dev page says is queued and not yet applied, for *this* project.
  #
  # Selected explicitly, because the page opens on whichever project sorts
  # first by name and a spec that skipped this would be reading some other
  # project's backlog — a number that is real, unrelated, and does not move
  # when this scenario acts.
  defp pending(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    ~r/data-test="backlog"[^>]*?data-pending="(\d+)"/
    |> Regex.run(html)
    |> then(fn
      [_match, count] -> String.to_integer(count)
      nil -> flunk("the dev page does not publish a backlog count")
    end)
  end
end
