defmodule CodeMySpecSpex.Story1062.Criterion3615Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3615 — A project requirement is not recomputed on a pass that did
  not move it.

  Rule: a project requirement is recomputed when its own inputs move, not on
  every pass.

  ## The last unconditional cost in a pass

  Every other entity is narrowed. Components and stories are recomputed only
  when `stale_entities/3` says their inputs moved; this story's other criteria
  are about keeping that true. Project requirements are the exception, and
  `compute_and_publish/3` says so in its own comment:

      # `ctx`, not `reduced`, and that is the measurement this exists to take.
      # Project nodes are rebuilt on every pass whatever the stale set says —
      # ten delegate checkers, several of which query the whole project

  So a pass that found one story stale still runs ten checkers over the whole
  project. On a pass that found *nothing* stale, they are the only thing it
  does, which makes them the floor cost of observing anything at all.

  ## Why that is worth a criterion rather than an optimisation note

  The rule this story is built on is that an observation costs work in
  proportion to what it changed. A fixed per-pass cost is the one shape that
  rule cannot absorb: it does not grow with what moved, it grows with how often
  anything moves, and this feature exists to make things move more often. The
  better the incremental sync gets, the larger this term is as a share of it.

  ## What it observes, and why not `checked_at`

  Queries, off the drain's own cost report.

  `checked_at` is the obvious instrument and it answers the wrong question here.
  A pass that reuses a project row still hands it to `upsert_all/3`, which
  stamps every row it is given — so the stamp moves whether the ten checkers
  ran or not, and the rule is about whether they ran. It is also
  second-resolution, which makes it blind inside a scenario anyway.

  Queries separate the two cleanly: the checkers are what the queries are.
  A pass whose project inputs held still issues materially fewer of them than
  one that had to re-derive the project, and that difference is the rule.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  @moduletag timeout: 60_000

  spex "A pass recomputes what moved, and the project's requirements are not that",
    criterion: 1511 do
    scenario "an observation bearing only on one story" do
      given_ :synced_context_component

      given_ "a settled graph with a story in it", context do
        story =
          create_story(context.scope,
            title: "The story the observation is about",
            description: "so the observation has somewhere to land"
          )

        :ok = Fixtures.settle_graph(context.scope)
        _warm = read_settled_graph(context)
        :ok = Fixtures.settle_graph(context.scope)

        assert read_graph(context)["nodes"] != [],
               "nothing is stored, so no pass can reuse anything"

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      when_ "an observation arrives that bears only on one component", context do
        # A finding recorded against one component. Chosen over editing a story
        # deliberately: `Freshness.project/1` hashes the whole
        # `delegated_inputs` map, so touching a story bumps its `updated_at`,
        # moves the `stories` stamp and moves the project fingerprint with it —
        # legitimately, under a fingerprint that coarse. Whether any project
        # requirement actually reads a story's *contents* rather than its
        # existence is a separate and narrower question, and not this one.
        #
        # `exunit` rather than `credo`, deliberately (story 1003, 2026-09-28):
        # `problems_resolved` now reads every `problems_changed` event to know
        # whether a story's own working copy carries a blocking credo/compiler
        # finding — a `credo` finding here would genuinely move it (this
        # project's own default working copy is a story's working copy too),
        # which is no longer the unambiguous "moved nothing" case this
        # scenario needs. `exunit` isn't in `problems_resolved`'s always-block
        # set, so it stays inert to every project *and* story requirement,
        # which is the property this scenario is actually about.
        :ok =
          Fixtures.replace_problems(context.scope, context.component.id, "exunit", [
            %{
              message: "Function body is nested too deep (max_nesting is 2).",
              file_path: "lib/reservations/booking.ex",
              line: 14
            }
          ])

        :ok = Fixtures.settle_graph(context.scope)
        untouched = queries(context)

        # And the other half: an issue filed moves `delegated_inputs`, which is
        # in the project's own fingerprint, so this pass genuinely has to
        # re-derive them. Without it there is no baseline and "cheaper" is a
        # number with nothing to be cheaper than.
        #
        # Joined by a blocking finding on the story's *own* copy (story 1003,
        # 2026-09-28): `problems_resolved` now reads every `problems_changed`
        # event, which costs the untouched pass above two fixed reads even
        # though nothing it finds there is relevant. An issue alone no longer
        # clears that floor by enough margin to mean anything; a credo finding
        # that actually blocks a story — a second, genuinely-moving kind in
        # the same drain — does.
        story = Stories.get_story(context.scope, context.story_id)

        {:ok, _story} =
          Stories.update_story(context.scope, story, %{
            working_copy_id: context.scope.active_working_copy_id
          })

        :ok =
          Fixtures.replace_problems(context.scope, context.component.id, "credo", [
            %{
              message: "Nested modules could be aliased at the top of the invoking module.",
              file_path: "lib/reservations/booking.ex",
              line: 1
            }
          ])

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, filed, _frame} =
          CreateIssue.execute(
            %{
              title: "something the project requirements read",
              description: "issues_triaged is a project requirement",
              severity: "medium",
              story_number: context.story_number
            },
            frame
          )

        refute filed.isError, inspect(filed)
        :ok = Fixtures.settle_graph(context.scope)

        {:ok, context |> Map.put(:untouched, untouched) |> Map.put(:moved, queries(context))}
      end

      then_ "both passes are measured", context do
        assert is_integer(context.untouched) and is_integer(context.moved),
               """
               One of the two passes did not report what it cost, so there is
               nothing to compare.

               project inputs held still: #{inspect(context.untouched)} queries
               project inputs moved:      #{inspect(context.moved)} queries
               """

        {:ok, context}
      end

      then_ "and the pass that did not move the project costs less", context do
        assert context.untouched < context.moved,
               """
               A pass whose project inputs held still cost
               #{context.untouched} queries, against #{context.moved} for one
               that had to re-derive them.

               Project requirements are ten delegate checkers, several of which
               query the whole project. Running them on a pass that could not
               have changed their answer is a fixed cost per observation — and a
               fixed cost is the one shape "work in proportion to what changed"
               cannot absorb: it does not grow with what moved, it grows with
               how often anything moves, and this feature exists to make things
               move more often.
               """

        {:ok, context}
      end
    end
  end

  # What the last pass cost, off the drain's own report — the same `last_drain`
  # criteria 3516 and 3517 read.
  defp queries(context), do: drain_queries(read_graph(context)["last_drain"])

  # Whichever writer serves the graph. `last_drain` on the read is the drain of
  # the writer the reader is served from — the pass, or the event path when it
  # is the source — so this measures the system as served and never mixes the
  # two, which is criterion 3516's comparison and not this one's.
  defp drain_queries(%{"queries" => queries}), do: queries
  defp drain_queries(_other), do: nil
end
