defmodule CodeMySpec.Requirements.FreshnessTest do
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import Ecto.Query
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Freshness, Preloader}
  alias CodeMySpec.Requirements.RequirementGraph

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "per-story fingerprints are stable, distinct, and stored", ctx do
    a = create_story(ctx.scope, title: "Story A", description: "one")
    b = create_story(ctx.scope, title: "Story B", description: "two")

    {:ok, c} = Preloader.load(ctx.scope)

    fa = Freshness.story(c, Enum.find(c.stories, &(&1.id == a.id)))
    fb = Freshness.story(c, Enum.find(c.stories, &(&1.id == b.id)))

    assert fa == Freshness.story(c, Enum.find(c.stories, &(&1.id == a.id))), "not stable"
    refute fa == fb, "two different stories hashed the same"

    # Reads serve rows; the write path computes and stores them, and this test
    # is about what gets stored.
    RequirementGraph.recompute(ctx.scope)
    {{nodes, _}, _} = RequirementGraph.cached_graph(ctx.scope)
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story"))
    refute story_nodes == [], "no story nodes computed"

    # Per vantage, because a fingerprint is a statement about one checkout.
    # `Freshness.story/2` hashes the story's files, and `Preloader.load/1`
    # scopes files to a working copy — so two vantages hashing the same story
    # legitimately disagree, and a pass maintains every vantage that has rows.
    # Reading across all of them and asserting agreement asserts that a
    # project has only ever been computed from one checkout.
    stored =
      Repo.all(
        from n in "requirements",
          where: n.story_id in ^[a.id, b.id],
          select: {n.story_id, n.working_copy_id, n.inputs_fingerprint}
      )

    refute stored == [], "nothing stored"

    assert Enum.all?(stored, fn {_, _, fp} -> is_binary(fp) end),
           "rows stored without a fingerprint: #{inspect(stored)}"

    by_entity =
      Enum.group_by(stored, fn {s, copy, _} -> {s, copy} end, fn {_, _, fp} -> fp end)

    Enum.each(by_entity, fn {{story_id, copy}, fingerprints} ->
      assert fingerprints |> Enum.uniq() |> length() == 1,
             "story #{story_id}'s rows disagree within vantage #{inspect(copy)}"
    end)

    # Two stories, same vantage, different answers.
    Enum.each(Enum.uniq(Enum.map(stored, fn {_, copy, _} -> copy end)), fn copy ->
      with [fa | _] <- by_entity[{a.id, copy}], [fb | _] <- by_entity[{b.id, copy}] do
        refute fa == fb,
               "stored fingerprints do not distinguish stories at vantage #{inspect(copy)}"
      end
    end)
  end
end
