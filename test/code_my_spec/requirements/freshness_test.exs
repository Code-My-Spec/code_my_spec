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

    {{nodes, _}, _} = RequirementGraph.cached_graph(ctx.scope)
    story_nodes = Enum.filter(nodes, &(&1.entity_type == "story"))
    refute story_nodes == [], "no story nodes computed"

    stored =
      Repo.all(
        from n in "requirements",
          where: n.story_id in ^[a.id, b.id],
          select: {n.story_id, n.inputs_fingerprint}
      )

    refute stored == [], "nothing stored"

    assert Enum.all?(stored, fn {_, fp} -> is_binary(fp) end),
           "rows stored without a fingerprint: #{inspect(stored)}"

    by_story = stored |> Enum.group_by(fn {s, _} -> s end, fn {_, fp} -> fp end)
    assert by_story[a.id] |> Enum.uniq() |> length() == 1, "one story's rows disagree"

    refute hd(by_story[a.id]) == hd(by_story[b.id]),
           "stored fingerprints do not distinguish stories"
  end
end
