defmodule CodeMySpec.AcceptanceCriteria.ClaimSpecPathsTest do
  @moduledoc """
  A criterion records where its spex file is, the first time a scan sees it.

  The convention writes the association into the filename —
  `criterion_<id>_<slug>_spex.exs` — and the scan reads the ids back out. So
  the link is derived in two directions from four things that all move: the
  story id, the story title, the criterion id and its description. When they
  stop agreeing the symptom is silent, because a criterion whose file cannot be
  matched reads as work not done rather than as an error.

  Measured on one project: 841 spex files against 921 criteria, 97 unmatched
  purely because ids had been renumbered and the files never renamed. Those
  files had been invisible to the requirement graph for as long as the ids had
  been stale.

  Claiming on sight makes the filename a name rather than an identifier.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.AcceptanceCriteria

  defp criterion(scope, story, attrs \\ %{}) do
    {:ok, c} =
      AcceptanceCriteria.create_criterion(
        scope,
        story,
        Map.merge(%{description: "a thing happens"}, attrs)
      )

    c
  end

  test "a criterion with no recorded path gets the one it was found at" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    c = criterion(scope, story)
    path = "test/spex/1_x/criterion_#{c.id}_a_thing_happens_spex.exs"

    assert {:ok, 1} = AcceptanceCriteria.claim_spec_paths(scope, %{c.id => path})
    assert AcceptanceCriteria.get_criterion(scope, c.id).spec_path == path
  end

  test "a criterion that already says is left alone" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    c = criterion(scope, story, %{spec_path: "test/spex/where/it/actually/is_spex.exs"})

    assert {:ok, 0} =
             AcceptanceCriteria.claim_spec_paths(scope, %{c.id => "test/spex/derived_spex.exs"})

    assert AcceptanceCriteria.get_criterion(scope, c.id).spec_path ==
             "test/spex/where/it/actually/is_spex.exs",
           "a recorded path outranks a derived one — otherwise renaming the file " <>
             "would silently re-point the criterion at wherever the convention " <>
             "says it should have been"
  end

  test "another project's criterion is not touched" do
    mine = full_scope_fixture()
    theirs = full_scope_fixture()
    c = criterion(theirs, story_fixture(theirs))

    assert {:ok, 0} = AcceptanceCriteria.claim_spec_paths(mine, %{c.id => "test/spex/x_spex.exs"})
    assert is_nil(AcceptanceCriteria.get_criterion(theirs, c.id).spec_path)
  end

  test "nothing to claim is not a query" do
    assert {:ok, 0} = AcceptanceCriteria.claim_spec_paths(full_scope_fixture(), %{})
  end
end
