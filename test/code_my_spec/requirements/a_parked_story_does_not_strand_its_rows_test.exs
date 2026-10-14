defmodule CodeMySpec.Requirements.AParkedStoryDoesNotStrandItsRowsTest do
  @moduledoc """
  A story that stops being ready takes its requirement rows with it.

  ## The loop this closes

  `Preloader` loads only `ready_for_dev` stories — a parked story must not
  project, or it would surface as actionable work nobody released. Correct, and
  it leaves a hole at the other end: the rows that story published while it *was*
  ready are still in the table, and nothing can rehydrate them.

  `Projection.rehydrate/2` resolves a row's entity out of the context
  (`Enum.find(ctx.stories, ...)`), finds nothing for a parked story, and drops
  the row. The read is then a strict subset of what the publish counted, and
  `served_graph/3` refuses the short read and recomputes — correctly, because a
  subset is not an answer.

  So every read of a project with a parked story costs a full recompute, for as
  long as the story stays parked. Measured on the live database while this was
  written: 63 rows across 8 parked stories on one project, 6 on another.

  ## Why the reap missed them

  `delete_departed/4` reaps rows belonging to *visited* entities that the write
  did not produce, and `visited/1` is built from `ctx.stories` — the ready set.
  A parked story is not in it, so its rows match no clause of the reap and
  survive every pass.

  Widening `visited` is not the fix: on an incremental pass it is deliberately
  the narrowed set, and reaping outside it would delete live rows. The reap
  instead asks the question directly — a row whose story is not ready is
  departed, whoever was visited — which is true on a full pass and an
  incremental one alike.
  """

  # Sync: failed under concurrency in the 2026-10-14 async sweep.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Stories

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope, %{ready_for_dev: true})

    Requirements.recompute(scope)

    rows = rows_for(story.id)

    assert rows > 0,
           "the ready story published no rows, so there is nothing for parking it to strand"

    %{scope: scope, story: story, rows_while_ready: rows}
  end

  test "parking a story reaps the rows it published", ctx do
    {:ok, _parked} = Stories.update_story(ctx.scope, ctx.story, %{ready_for_dev: false})

    Requirements.recompute(ctx.scope)

    assert rows_for(ctx.story.id) == 0,
           """
           A story was parked and #{rows_for(ctx.story.id)} of its requirement
           rows survived the next pass.

           `Preloader` will not load a parked story, so `rehydrate/2` cannot
           resolve those rows to an entity and drops them. Every subsequent read
           is then shorter than the count the publish recorded, `served_graph/3`
           refuses it, and the graph is recomputed in full — on every read, for
           as long as the story stays parked.

           rows while ready: #{ctx.rows_while_ready}
           rows after parking: #{rows_for(ctx.story.id)}
           """
  end

  # The same hole, reached by the other route, and structurally worse.
  #
  # `requirements.component_id` has a foreign key with `ON DELETE CASCADE`, so a
  # deleted component takes its rows with it and none of this arises.
  # `story_id` has no foreign key at all — the rows simply outlive the story,
  # and `delete_departed/4` cannot reach them because a deleted story is never
  # visited either.
  #
  # Measured on the live database while this was written: 385 rows across 60
  # stories that no longer exist.
  test "retiring a story reaps the rows it published", ctx do
    {:ok, _retired} = Stories.retire_story(ctx.scope, ctx.story)

    Requirements.recompute(ctx.scope)

    assert rows_for(ctx.story.id) == 0,
           """
           A story was retired and #{rows_for(ctx.story.id)} of its requirement
           rows survived the next pass.

           Nothing can ever resolve them again — the story is gone from the
           table, so `rehydrate/2` drops every one, the read is short, and
           `served_graph/3` recomputes the whole graph. Permanently, because no
           later pass will visit an entity that does not exist.

           rows while the story existed: #{ctx.rows_while_ready}
           rows after retiring it:       #{rows_for(ctx.story.id)}
           """
  end

  test "a story that is still ready keeps its rows", ctx do
    Requirements.recompute(ctx.scope)

    assert rows_for(ctx.story.id) == ctx.rows_while_ready,
           """
           A released story lost rows across a pass that changed nothing.

           This is the half the reap must not break: the predicate is "this
           story is not ready", and a reap that answered on anything else —
           whether the pass happened to visit it, say — would take live rows
           with it on every incremental pass.
           """
  end

  defp rows_for(story_id) do
    Node |> where([n], n.story_id == ^story_id) |> Repo.aggregate(:count)
  end
end
