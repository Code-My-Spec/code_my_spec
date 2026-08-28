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

  test "a criterion whose recorded file is really there is left alone" do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    # A real file, and deliberately not where the convention would put it.
    # This used to record a path that existed nowhere, which made it stand for
    # "a recorded path" without standing for a resolvable one — and those are
    # the two cases this function now has to tell apart.
    actual =
      Path.join(
        System.tmp_dir!(),
        "claim_spec_paths_#{System.unique_integer([:positive])}_spex.exs"
      )

    File.write!(actual, "# a spex somebody put somewhere deliberate\n")
    on_exit(fn -> File.rm(actual) end)

    c = criterion(scope, story, %{spec_path: actual})

    assert {:ok, 0} =
             AcceptanceCriteria.claim_spec_paths(scope, %{c.id => "test/spex/derived_spex.exs"})

    assert AcceptanceCriteria.get_criterion(scope, c.id).spec_path == actual,
           "a recorded path that resolves outranks a derived one — otherwise " <>
             "moving a spex somewhere deliberate would be undone by the next scan"
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

  test "a recorded path whose file is gone is repaired" do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    stale = "test/spex/1_x/criterion_999999_under_its_old_name_spex.exs"
    c = criterion(scope, story, %{spec_path: stale})

    refute File.exists?(stale), "the premise is that the recorded file is gone"

    found = "test/spex/1_x/criterion_#{c.id}_under_its_new_name_spex.exs"

    assert {:ok, 1} = AcceptanceCriteria.claim_spec_paths(scope, %{c.id => found}),
           "a criterion pointing at a file that no longer exists was left pointing " <>
             "at it. Renaming a spex is the normal consequence of rewording its " <>
             "criterion, and the record then names a file nobody will create " <>
             "again — `bdd_specs_exist` reads the record, finds nothing, and " <>
             "reports a spec that is sitting in the same directory."

    assert AcceptanceCriteria.get_criterion(scope, c.id).spec_path == found
  end
end
