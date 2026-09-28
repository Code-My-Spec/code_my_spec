defmodule CodeMySpecSpex.Story1062.Criterion3521Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3521 — A mark is discarded only once its work is done.

  Rule: a mark is consumed after the writes it asks for, never before.

  ## The ordering is the whole rule

  Consuming first is the natural way to write a queue drain — take the batch,
  mark it taken, do the work — and it is the one ordering that cannot recover.
  A failure part-way through then leaves the entities half-settled with nothing
  left to say they need finishing: the graph serves stale answers and the
  record of which ones is gone.

  Consuming last has the opposite failure, and it is the survivable one. A crash
  after the writes and before the delete leaves the mark in place, so the work
  is done again. Settling is idempotent — it writes verdicts computed from
  current inputs — so doing it twice costs a drain and changes nothing.

  [[Criterion 3520]] is the other half of the same design: marks are durable so
  they outlive the process. This is what makes that durability worth having,
  because a mark that survives the process but is consumed before its work is
  not a record of anything.

  ## What "fails part way through" means here

  The recompute raising, injected as a fault. Not a contrived exception at the
  call site — the point is a drain that genuinely began, did some of what it
  came to do, and stopped. The mark's fate is decided by code that has already
  started running.

  ## Surface

  The graph dev page's backlog panel, same as [[criterion 3520]]. "Left in place
  to be applied again" is a claim about a queue somebody can look at, and the
  backlog is where the 610-mark pile-up of 2026-09-17 was eventually seen.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :restore_projector

  @endpoint CodeMySpecWeb.Endpoint

  # A broken recompute is a crash loop, and the default 180s timeout turns any
  # mistake in driving it into a three-minute wait. Fail fast instead.
  @moduletag timeout: 45_000

  defp restore_projector(_context) do
    previous = Application.get_env(:code_my_spec, :graph_shadow_projection, false)
    on_exit(fn -> Application.put_env(:code_my_spec, :graph_shadow_projection, previous) end)
    :ok
  end

  spex "A failed drain leaves its marks to be applied again", criterion: 1429 do
    scenario "the recompute raises part way through applying an observation" do
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

      given_ "an observation queued and not yet applied", context do
        # Recorded with nothing running to drain it, for the reason
        # [[criterion 3520]] records: the applier is eager, so a mark made while
        # it is up is gone before anything can look.
        Fixtures.stop_graph_watchers()

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something is wrong on this story",
              description: "queued while nothing was running to apply it",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)

        {:ok, Map.put(context, :queued, pending(context))}
      end

      when_ "the work it asks for fails part way through", context do
        :ok = Fixtures.break_graph_recompute(context.scope)

        # Driven by a read, and with no watcher restarted. Two things this
        # scenario learned the expensive way: `GraphWatcher.settle/2` is a
        # `GenServer.call` into the process that is now raising on every pass,
        # so it never returns; and restarting the watcher under an injected
        # fault is a crash loop that hangs anything waiting on it. A read
        # drives the pending observation through the failing path and waits on
        # nothing.
        capture_log(fn -> read_graph(context) end)

        # The raise is the thing this scenario asked for, and
        # `SexySpex.ErrorCapture` is a `:logger` handler that records it
        # independently of `capture_log` — so the run would fail on the very
        # failure being asserted unless the expectation is declared. Cleared
        # after the drive, before the backlog is read.
        SexySpex.ErrorCapture.clear()

        {:ok, Map.put(context, :after_failure, pending(context))}
      end

      then_ "there was work queued for the failed drain to attempt", context do
        assert context.queued > 0,
               """
               Nothing was queued, so the drain had nothing to fail at and this
               scenario proves nothing about what a failure does to a mark.
               """

        {:ok, context}
      end

      then_ "and the mark is left in place to be applied again", context do
        assert context.after_failure >= context.queued,
               """
               #{context.queued} mark(s) were queued and #{context.after_failure}
               remain after a drain that failed.

               A mark consumed on the strength of having been started is the one
               ordering that cannot recover. The entities it named are left
               half-settled, the graph serves those answers as though they were
               computed normally, and the record of which ones needed finishing
               went with the mark.

               Doing the work twice is the cheap failure and is the one this
               design chooses: settling is idempotent, so a mark applied again
               costs a drain and changes nothing.

               queued:          #{context.queued}
               after a failure: #{context.after_failure}
               """

        {:ok, context}
      end
    end
  end

  # What the dev page says is queued and not yet applied, for *this* project.
  # Selected explicitly: the page opens on whichever project sorts first by
  # name, which is some other project's backlog.
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
