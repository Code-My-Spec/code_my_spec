defmodule CodeMySpecSpex.Story1062.Criterion3516Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3516 — Applying an observation costs less than recomputing it.

  Rule: the cheaper path is measurably cheaper, and the measurement is
  published.

  ## The claim the whole feature rests on

  Applying an observation is only worth the handler table, the durable marks and
  the vocabulary if it is cheaper than re-deriving from them. That is a number,
  not an argument — and until it is measured the feature is a design somebody
  believes in.

  Both paths run on the same settle here, against the same observation, which is
  what makes the comparison fair. One is a handler writing the verdict it
  already knew; the other is a full recompute of every requirement the entity
  carries. Story 1020 measured the second at 22 checkers and 238ms for a single
  incoming issue.

  ## Queries and rows, not milliseconds

  Duration measures the machine. The same seventeen-query drain has been seen at
  4ms and at 18ms per query inside one minute on a loaded box, so a criterion
  written on time would be red on a busy afternoon and green at night.

  Queries and rows written say the same thing about either implementation, which
  is what lets this criterion survive the swap it exists to justify.

  ## Why both numbers and not just queries

  A projection can trade one for the other. Settling story issue submission readiness is
  one `UPDATE` across every story's row plus the exceptions — few queries, many
  rows — so a rule written on queries alone would call that an improvement while
  it stamped the whole table. Requiring neither to be worse is the honest form of
  "costs less".

  ## Surface

  The graph dev page publishes the last drain of each kind side by side, which
  is the comparison rather than a number to be compared by hand. "The difference
  is reported rather than inferred" is the second half of the criterion, and a
  page that showed one kind at a time would fail it however good the numbers
  were.
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

  defp project_the_marks(_context) do
    previous = Application.get_env(:code_my_spec, :graph_shadow_projection, false)
    Application.put_env(:code_my_spec, :graph_shadow_projection, true)
    on_exit(fn -> Application.put_env(:code_my_spec, :graph_shadow_projection, previous) end)
    :ok
  end

  spex "Applying is cheaper than re-deriving, and the difference is published", criterion: 1425 do
    scenario "one observation drained both ways" do
      given_(:synced_context_component)

      given_ "a settled graph with something to file against", context do
        _settled = read_settled_graph(context)

        # The projector is started by the watcher and only if the flag is on
        # when the watcher starts. One already exists by here, so it must be
        # rebuilt for the pair to run.
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

      when_ "an observation of a kind the graph knows how to apply is drained", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something the graph knows how to settle",
              description: "issue_created has a handler, so both paths answer it",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, Map.put(context, :drains, drains(context))}
      end

      then_ "both costs are reported rather than inferred", context do
        assert context.drains.event,
               """
               The page publishes no `event` drain, so the cheaper path's cost
               is not reported at all and "cheaper" cannot be checked.
               """

        assert context.drains.pass,
               """
               The page publishes no `pass` drain, so there is nothing to
               compare the applied cost against.
               """

        {:ok, context}
      end

      then_ "and applying reports fewer queries than recomputing", context do
        %{event: applied, pass: recomputed} = context.drains

        assert applied.queries < recomputed.queries,
               """
               Applying the observation took #{applied.queries} queries and
               recomputing took #{recomputed.queries}.

               An issue arriving at the gating severity *is*
               `issues_triaged = false` — there is nothing to ask. Re-deriving
               the same answer ran 22 checkers for one incoming issue. If the
               handler path is not cheaper, the handler table, the durable marks
               and the vocabulary are all cost with nothing bought.

               applied:    #{applied.queries} queries, #{applied.rows_written} rows
               recomputed: #{recomputed.queries} queries, #{recomputed.rows_written} rows
               """

        {:ok, context}
      end

      then_ "and it writes no more rows than recomputing", context do
        %{event: applied, pass: recomputed} = context.drains

        assert applied.rows_written <= recomputed.rows_written,
               """
               Applying wrote #{applied.rows_written} rows and recomputing wrote
               #{recomputed.rows_written}.

               Queries alone can be traded for rows: settling one requirement
               across every story is few queries and many rows, which a
               query-only rule would call an improvement while it stamped the
               whole table. Neither number being worse is what "costs less"
               has to mean.

               applied:    #{applied.queries} queries, #{applied.rows_written} rows
               recomputed: #{recomputed.queries} queries, #{recomputed.rows_written} rows
               """

        {:ok, context}
      end
    end
  end

  # The last drain of each kind, as the page publishes them side by side.
  defp drains(context) do
    {:ok, view, _html} = live(context.conn, "/dev/graph")
    html = render_change(view, "select", %{"project" => context.project.id})

    %{event: row(html, "event"), pass: row(html, "pass")}
  end

  defp row(html, kind) do
    ~r/data-test="drain" data-kind="#{kind}"(.*?)<\/div>/s
    |> Regex.run(html)
    |> then(fn
      [_match, body] ->
        %{
          queries: number(body, "drain-queries"),
          rows_written: number(body, "drain-rows-written")
        }

      nil ->
        nil
    end)
  end

  defp number(body, test_id) do
    ~r/data-test="#{test_id}"[^>]*>\s*(\d+)/
    |> Regex.run(body)
    |> then(fn
      [_match, value] -> String.to_integer(value)
      nil -> nil
    end)
  end
end
