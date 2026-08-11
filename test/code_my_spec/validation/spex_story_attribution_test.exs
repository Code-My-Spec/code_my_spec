defmodule CodeMySpec.Validation.SpexStoryAttributionTest do
  @moduledoc """
  A spex failure belongs to the story its criterion names, not to the number in
  its directory.

  Spex enforcement is gated per story: a failure only blocks when the owning
  story's `specs_ready` latch is set, which is what makes enabling spex
  project-wide survivable. That gate read the leading number out of
  `test/spex/<n>_.../` and used it as a story id.

  Those numbers are directory names and have drifted from the ids. Measured on
  this project: `811_user_sees_the_agents_task_queue_at_a_glance` derives 811 —
  a real story, "Onboarding lives at /app", not ready — while the story with
  that title is 862, which is ready. So a latched story gated nothing (no path
  derives 862) and an unlatched one gated spex that were not its own.

  Both wrong answers are silent, because a number resolving to *a* story looks
  identical to one resolving to the right story. `criteria.spec_path` is the
  recorded answer — written by `claim_spec_paths/2` when the file is created,
  which is why it survives a rename — and is what these assert on.

  The directory number here is deliberately one that cannot be any story's id,
  so a test passing by coincidence is not possible.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AcceptanceCriteria

  @dir_number 999_111
  @path "test/spex/#{@dir_number}_a_directory_named_for_nothing/criterion_1_spex.exs"

  defp claim(scope, story, path) do
    {:ok, criterion} =
      AcceptanceCriteria.create_criterion(scope, story, %{
        description: "a criterion",
        spec_path: path
      })

    criterion
  end

  test "a spex path resolves to the story whose criterion claimed it" do
    scope = full_scope_fixture()
    story = story_fixture(scope)
    claim(scope, story, @path)

    assert %{@path => story_id} = AcceptanceCriteria.spec_path_story_ids(scope)
    assert story_id == story.id

    refute story_id == @dir_number,
           "resolved to the number in the directory rather than to the owning story"
  end

  test "an unclaimed path is absent rather than guessed at" do
    scope = full_scope_fixture()
    _story = story_fixture(scope)

    refute Map.has_key?(AcceptanceCriteria.spec_path_story_ids(scope), @path),
           "an absent answer is what lets the caller fall back deliberately; a " <>
             "guessed one is the bug"
  end

  test "two spex under one directory resolve independently" do
    # The drift is per criterion, not per directory: nothing guarantees that two
    # files sharing a directory belong to the same story once ids have moved.
    scope = full_scope_fixture()
    a = story_fixture(scope)
    b = story_fixture(scope)

    path_a = "test/spex/#{@dir_number}_shared/criterion_a_spex.exs"
    path_b = "test/spex/#{@dir_number}_shared/criterion_b_spex.exs"

    claim(scope, a, path_a)
    claim(scope, b, path_b)

    resolved = AcceptanceCriteria.spec_path_story_ids(scope)

    assert Map.get(resolved, path_a) == a.id
    assert Map.get(resolved, path_b) == b.id
    refute a.id == b.id
  end
end
