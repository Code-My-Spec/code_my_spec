defmodule CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepositoryTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.AcceptanceCriteria.AcceptanceCriteriaRepository
  alias CodeMySpec.AcceptanceCriteria.Criterion

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  describe "list_story_criteria/2" do
    test "returns all criteria for the story ordered by inserted_at" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})

      criterion1 = criterion_fixture(scope, story, %{description: "First"})
      criterion2 = criterion_fixture(scope, story, %{description: "Second"})
      criterion3 = criterion_fixture(scope, story, %{description: "Third"})

      criteria = AcceptanceCriteriaRepository.list_story_criteria(scope, story.id)

      assert length(criteria) == 3
      assert Enum.at(criteria, 0).id == criterion1.id
      assert Enum.at(criteria, 1).id == criterion2.id
      assert Enum.at(criteria, 2).id == criterion3.id
    end

    test "returns empty list when story has no criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})

      criteria = AcceptanceCriteriaRepository.list_story_criteria(scope, story.id)

      assert criteria == []
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope, %{criteria: []})
      other_story = story_fixture(other_scope, %{criteria: []})

      _criterion1 = criterion_fixture(scope, story, %{description: "In scope"})
      _criterion2 = criterion_fixture(other_scope, other_story, %{description: "Out of scope"})

      criteria = AcceptanceCriteriaRepository.list_story_criteria(scope, story.id)

      assert length(criteria) == 1
      assert hd(criteria).description == "In scope"
    end
  end

  describe "get_criterion!/2" do
    test "returns criterion when it exists in project" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      result = AcceptanceCriteriaRepository.get_criterion!(scope, criterion.id)

      assert result.id == criterion.id
      assert result.description == criterion.description
    end

    test "raises Ecto.NoResultsError when criterion doesn't exist" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        AcceptanceCriteriaRepository.get_criterion!(scope, 999_999)
      end
    end

    test "raises Ecto.NoResultsError when criterion exists but in different project" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(other_scope)
      criterion = criterion_fixture(other_scope, story)

      assert_raise Ecto.NoResultsError, fn ->
        AcceptanceCriteriaRepository.get_criterion!(scope, criterion.id)
      end
    end
  end

  describe "get_criterion/2" do
    test "returns criterion when it exists in project" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      result = AcceptanceCriteriaRepository.get_criterion(scope, criterion.id)

      assert result.id == criterion.id
      assert result.description == criterion.description
    end

    test "returns nil when criterion doesn't exist" do
      scope = full_scope_fixture()

      result = AcceptanceCriteriaRepository.get_criterion(scope, 999_999)

      assert is_nil(result)
    end

    test "returns nil when criterion exists but in different project" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(other_scope)
      criterion = criterion_fixture(other_scope, story)

      result = AcceptanceCriteriaRepository.get_criterion(scope, criterion.id)

      assert is_nil(result)
    end
  end

  describe "create_criterion/3" do
    test "creates criterion with valid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:ok, %Criterion{} = criterion} =
               AcceptanceCriteriaRepository.create_criterion(scope, story, %{
                 description: "Test criterion",
                 verified: false
               })

      assert criterion.description == "Test criterion"
      assert criterion.story_id == story.id
      assert criterion.project_id == scope.active_project.id
    end

    test "returns changeset error for invalid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               AcceptanceCriteriaRepository.create_criterion(scope, story, %{description: nil})
    end

    test "rejects cross-project stories" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(other_scope)

      assert {:error, :cross_project} =
               AcceptanceCriteriaRepository.create_criterion(scope, story, %{
                 description: "Test"
               })
    end
  end

  describe "update_criterion/3" do
    test "updates criterion with valid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, %Criterion{} = updated} =
               AcceptanceCriteriaRepository.update_criterion(scope, criterion, %{
                 description: "Updated description"
               })

      assert updated.description == "Updated description"
      assert updated.id == criterion.id
    end

    test "returns changeset error for invalid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:error, %Ecto.Changeset{}} =
               AcceptanceCriteriaRepository.update_criterion(scope, criterion, %{
                 description: nil
               })
    end

    test "rejects cross-project criteria" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(other_scope)
      criterion = criterion_fixture(other_scope, story)

      assert {:error, :cross_project} =
               AcceptanceCriteriaRepository.update_criterion(scope, criterion, %{
                 description: "x"
               })
    end
  end

  describe "delete_criterion/2" do
    test "deletes criterion successfully" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, %Criterion{}} = AcceptanceCriteriaRepository.delete_criterion(scope, criterion)

      assert is_nil(AcceptanceCriteriaRepository.get_criterion(scope, criterion.id))
    end

    test "returns deleted criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, deleted} = AcceptanceCriteriaRepository.delete_criterion(scope, criterion)

      assert deleted.id == criterion.id
      assert deleted.description == criterion.description
    end

    test "rejects cross-project criteria" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(other_scope)
      criterion = criterion_fixture(other_scope, story)

      assert {:error, :cross_project} =
               AcceptanceCriteriaRepository.delete_criterion(scope, criterion)
    end
  end

  defp criterion_fixture(scope, story, attrs \\ %{}) do
    attrs = Enum.into(attrs, %{description: "Test criterion description", verified: false})
    {:ok, criterion} = AcceptanceCriteriaRepository.create_criterion(scope, story, attrs)
    criterion
  end
end
