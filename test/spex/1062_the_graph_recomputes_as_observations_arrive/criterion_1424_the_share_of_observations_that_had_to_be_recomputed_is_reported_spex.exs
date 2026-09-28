defmodule CodeMySpecSpex.Story1062.Criterion3515Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3515 — The share of observations that had to be recomputed is
  reported.

  Rule: a drain says how much of its work it applied and how much it re-derived.

  ## Why the split has to be reported and not inferred

  Handlers arrive one kind at a time, so for most of this feature's life the
  projection is a mixture: some observations settle a verdict directly, the rest
  fall back to recomputing the entities they named. Both produce a correct
  graph. Only one of them is the feature.

  Without the split, a drain that applied everything and a drain that fell back
  for everything are the same event — same announcement, same updated rows, same
  duration band — and "incremental sync works" becomes a claim nobody can check.
  Worse, it can regress silently: a handler removed, or a writer switched to a
  kind nothing handles, shows up as no change at all.

  So the numbers are published, and this asserts they move. A report that always
  says the same thing is not a measurement.

  ## The two drains

  `issue_created` has a handler; `story_created` does not and is on the
  falls-back list on purpose — handlers settle rows and never create them, so an
  event that decides whether an entity projects at all cannot be applied.

  That makes them the honest contrasting pair: one observation the graph knows
  how to settle, one it can only re-derive from, driven through the same path
  and read off the same report.

  ## Surface

  The graph dev page's last-drain panel, which publishes `settled` and
  `recomputed` beside the queries and rows. The criterion says the pass "reports"
  the share, and a number that exists only inside a telemetry payload is not
  reported to anybody.
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
  @moduletag timeout: 60_000

  # The applied-versus-re-derived split only exists on the event path, and that
  # path is off by default outside dev. Filed as `e0729ea9`; not this
  # criterion's subject.
  defp project_the_marks(_context) do
    previous = Application.get_env(:code_my_spec, :graph_shadow_projection, false)
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    on_exit(fn -> Application.put_env(:code_my_spec, :graph_shadow_projection, previous) end)
    :ok
  end

  spex "A drain reports how much of its work it applied", criterion: 1424 do
    scenario "one observation the graph can apply, and one it can only re-derive from" do
      given_ :synced_context_component

      given_ "a settled graph with something to file against", context do
        _settled = read_settled_graph(context)

        # The projector is started by the watcher, and only if the flag is on at
        # the moment the watcher starts. By here a watcher already exists — the
        # graph has been read — so it was started before the setup block flipped
        # the flag and no projector came with it. Stopping forces the next
        # `watch_graph/1` to build the pair.
        Fixtures.stop_graph_watchers()
        Fixtures.watch_graph(context.scope)
        :ok = Fixtures.settle_graph(context.scope)

        story =
          create_story(context.scope,
            title: "The story the issue is about",
            description: "so the observation names something"
          )

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      when_ "an observation the graph can apply is drained", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something the graph knows how to settle",
              description: "issue_created has a handler",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :applied_drain, drain(context))}
      end

      when_ "and an observation it can only re-derive from is drained", context do
        create_story(context.scope,
          title: "Arrived by a route nothing applies",
          description: "story_created falls back on purpose"
        )

        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :fallback_drain, drain(context))}
      end

      then_ "the drain says how many it settled and how many it recomputed", context do
        for {label, reading} <- [
              {"applied", context.applied_drain},
              {"fallback", context.fallback_drain}
            ] do
          assert is_integer(reading.handled) and is_integer(reading.recomputed),
                 """
                 The #{label} drain did not publish the applied/re-derived split:
                 settled #{inspect(reading.handled)}, recomputed
                 #{inspect(reading.recomputed)}.

                 Without both numbers a drain that applied everything and one
                 that fell back for everything are the same event, and
                 "incremental sync works" is a claim with no evidence behind it.
                 """
        end

        {:ok, context}
      end

      then_ "and a drain that fell back is distinguishable from one that applied", context do
        applied = context.applied_drain
        fallback = context.fallback_drain

        refute {applied.handled, applied.recomputed} == {fallback.handled, fallback.recomputed},
               """
               Both drains report the same split, so the report cannot tell the
               feature working from the feature absent.

               applied-kind drain:  settled #{applied.handled}, recomputed #{applied.recomputed}
               fallback-kind drain: settled #{fallback.handled}, recomputed #{fallback.recomputed}

               `issue_created` has a handler and `story_created` is on the
               falls-back list. A report that answers identically for both is
               reporting something other than what it claims to.
               """

        {:ok, context}
      end
    end
  end

  # The last drain, as the dev page publishes it.
  #
  # The project is selected explicitly: the page opens on whichever project
  # sorts first by name, which would be some other project's drain.
  defp drain(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    event_row(html)
  end

  # The `event` drain's row, which is the one carrying the applied-versus-
  # re-derived split. The page publishes the last of each kind side by side;
  # the `pass` row is a whole recompute and reports no split at all.
  defp event_row(html) do
    ~r/data-test="drain" data-kind="event"(.*?)<\/div>/s
    |> Regex.run(html)
    |> then(fn
      [_match, row] ->
        %{
          present?: true,
          handled: number(row, "drain-handled"),
          recomputed: number(row, "drain-recomputed"),
          queries: number(row, "drain-queries"),
          rows_written: number(row, "drain-rows-written")
        }

      nil ->
        %{present?: false, handled: nil, recomputed: nil, queries: nil, rows_written: nil}
    end)
  end

  defp number(row, test_id) do
    ~r/data-test="#{test_id}"[^>]*>\s*(?:settled|recomputed)?\s*(\d+)/
    |> Regex.run(row)
    |> then(fn
      [_match, value] -> String.to_integer(value)
      nil -> nil
    end)
  end
end
