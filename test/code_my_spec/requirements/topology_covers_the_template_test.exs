defmodule CodeMySpec.Requirements.TopologyCoversTheTemplateTest do
  @moduledoc """
  The edges come from the requirement templates, so a template change has to
  move the topology fingerprint.

  It did not. `CachedGraph.topology_fingerprint`'s own comment said "it moves
  when a dependency, a parent or the config moves, and those are the only things
  that change an edge" — the templates were the unlisted fourth thing.

  Measured 2026-09-23: `story_issues_resolved` moved ahead of `qa_complete` and
  shipped in v2.0.152. The module loaded and the rendered description changed,
  while the served graph went on offering `qa_complete` whose prerequisite was
  now unsatisfied, across 17 vantages on two projects. Only the vantage that
  happened to receive an entity write picked up the new shape.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Freshness

  defp ctx, do: %{components: [], stories: []}

  test "the topology fingerprint covers the requirement definitions" do
    parts = Freshness.topology_parts(ctx(), %{devops: :off})

    assert Map.has_key?(parts, :definitions),
           """
           Without a definitions digest, changing a prerequisite leaves the
           topology fingerprint identical, `topology_moved?` false, and every
           partial recompute keeps the stale stored edges.
           """
  end

  test "it is stable when nothing about the templates changed" do
    a = Freshness.topology(ctx(), %{devops: :off})
    b = Freshness.topology(ctx(), %{devops: :off})

    assert a == b, "an unchanged template must not look like a new shape"
  end

  test "config still moves it, and independently of the definitions" do
    off = Freshness.topology(ctx(), %{devops: :off})
    on = Freshness.topology(ctx(), %{devops: :uat})

    refute off == on,
           "config decides which definitions exist, so it still has to move the shape"
  end
end
