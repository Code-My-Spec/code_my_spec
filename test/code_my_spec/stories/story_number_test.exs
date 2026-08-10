defmodule CodeMySpec.Stories.StoryNumberTest do
  @moduledoc """
  A story's durable name, as distinct from its primary key.

  `id` is a per-deployment sequence and renumbers on migration. Spex
  directories and QA folders are named from it, so after a renumber the files
  pointed at stories they were never written for — measured on this project as a
  uniform drift of 51: `test/spex/811_user_sees_the_agents_task_queue…` named a
  real but unrelated story 811, while the story owning those spex was 862.

  `number` is minted once and never moves, so a path keeps meaning what it said.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story

  test "a new story is minted a number" do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    assert is_integer(story.number)
  end

  test "numbers increase and do not collide within a project" do
    scope = full_scope_fixture()

    numbers = for _ <- 1..3, do: story_fixture(scope).number

    assert numbers == Enum.uniq(numbers)
    assert numbers == Enum.sort(numbers)
  end

  test "deleting the highest story frees its number for reuse" do
    # Asserted rather than left unsaid, because it is a deliberate trade and the
    # opposite is the intuitive expectation.
    #
    # Preventing reuse needs a counter that outlives the rows, and the only
    # place to keep one is the project — which makes every story insert lock the
    # project row and mixes sequence state into it. That price is not worth
    # paying now that attribution runs through `criteria.spec_path` rather than
    # through the number in a directory name: a recycled number under a
    # different title is a different directory, so nothing is misattributed.
    #
    # If this ever does bite, the fix is a dedicated counters table, not a
    # column on projects.
    scope = full_scope_fixture()
    highest = story_fixture(scope)

    {:ok, _} = Stories.delete_story(scope, highest)

    assert story_fixture(scope).number == highest.number
  end

  test "an explicitly supplied number is kept" do
    # How a migration carries a story's name across deployments: the number is
    # the thing being preserved, so it must survive the insert.
    scope = full_scope_fixture()

    {:ok, story} =
      Stories.create_story(scope, %{
        title: "carried across",
        story: "as a user, i want my story to keep its name",
        number: 4242
      })

    assert story.number == 4242
  end

  test "two projects number independently" do
    a = full_scope_fixture()
    b = full_scope_fixture()

    first_in_a = story_fixture(a)
    first_in_b = story_fixture(b)

    assert first_in_a.number == first_in_b.number,
           "numbering is per project, so each starts from its own sequence"

    refute first_in_a.project_id == first_in_b.project_id
  end

  test "the backfilled column is unique per project" do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    assert_raise Ecto.ConstraintError, fn ->
      Repo.insert!(%Story{
        title: "duplicate number",
        story: "duplicate",
        description: "duplicate",
        project_id: story.project_id,
        account_id: story.account_id,
        number: story.number,
        first_version_id: story.first_version_id,
        current_version_id: story.current_version_id
      })
    end
  end
end
