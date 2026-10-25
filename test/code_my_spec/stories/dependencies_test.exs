defmodule CodeMySpec.Stories.DependenciesTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  alias CodeMySpec.Stories

  test "duplicate links are idempotent and removal preserves other links" do
    scope = full_scope_fixture()
    first = story_fixture(scope)
    second = story_fixture(scope)
    third = story_fixture(scope)

    assert {:ok, :ok} = Stories.add_story_dependency(scope, third.number, first.number)
    assert {:ok, :ok} = Stories.add_story_dependency(scope, third.number, first.number)
    assert {:ok, :ok} = Stories.add_story_dependency(scope, third.number, second.number)
    assert length(Stories.list_story_dependencies(scope, third.id).builds_on) == 2
    assert {:ok, :ok} = Stories.remove_story_dependency(scope, third.number, first.number)
    assert [remaining] = Stories.list_story_dependencies(scope, third.id).builds_on
    assert remaining.id == second.id
    assert Stories.list_story_dependencies(scope, first.id).built_on_by == []
  end

  test "an indirect cycle reports its ordered loop without inserting the edge" do
    scope = full_scope_fixture()
    first = story_fixture(scope)
    second = story_fixture(scope)
    third = story_fixture(scope)

    assert {:ok, :ok} = Stories.add_story_dependency(scope, first.number, second.number)
    assert {:ok, :ok} = Stories.add_story_dependency(scope, second.number, third.number)
    assert {:error, message} = Stories.add_story_dependency(scope, third.number, first.number)

    assert message ==
             "Story dependency cycle: #{third.number} -> #{first.number} -> #{second.number} -> #{third.number}"

    assert Stories.list_story_dependencies(scope, third.id).builds_on == []

    assert {:error, "a story cannot build on itself"} =
             Stories.add_story_dependency(scope, first.number, first.number)
  end

  test "numbers resolve within the caller's project and reads cannot expose foreign links" do
    scope = full_scope_fixture()
    other_scope = full_scope_fixture()
    first = story_fixture(scope)
    second = story_fixture(scope)
    other_first = story_fixture(other_scope)
    other_second = story_fixture(other_scope)

    assert {:ok, :ok} =
             Stories.add_story_dependency(other_scope, other_second.number, other_first.number)

    assert Stories.list_story_dependencies(scope, other_second.id) ==
             %{builds_on: [], built_on_by: []}

    assert {:ok, :ok} = Stories.remove_story_dependency(scope, second.number, first.number)
    assert [preserved] = Stories.list_story_dependencies(other_scope, other_second.id).builds_on
    assert preserved.id == other_first.id

    assert {:error, "Story not found in this project"} =
             Stories.add_story_dependency(scope, second.number, 2_000_000_000)
  end
end
