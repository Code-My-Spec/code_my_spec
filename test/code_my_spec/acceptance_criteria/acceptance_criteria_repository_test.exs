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

  describe "create_criterion/1" do
    test "creates criterion with valid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      attrs = valid_criterion_attrs(scope, story)

      assert {:ok, %Criterion{} = criterion} =
               AcceptanceCriteriaRepository.create_criterion(attrs)

      assert criterion.description == attrs.description
      assert criterion.story_id == story.id
      assert criterion.project_id == scope.active_project.id
    end

    test "returns changeset error for invalid attributes" do
      attrs = %{description: nil}

      assert {:error, %Ecto.Changeset{}} =
               AcceptanceCriteriaRepository.create_criterion(attrs)
    end

    test "validates required fields" do
      attrs = %{}

      assert {:error, changeset} = AcceptanceCriteriaRepository.create_criterion(attrs)

      assert %{
               description: ["can't be blank"],
               story_id: ["can't be blank"],
               project_id: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  describe "update_criterion/2" do
    test "updates criterion with valid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      update_attrs = %{description: "Updated description"}

      assert {:ok, %Criterion{} = updated_criterion} =
               AcceptanceCriteriaRepository.update_criterion(criterion, update_attrs)

      assert updated_criterion.description == "Updated description"
      assert updated_criterion.id == criterion.id
    end

    test "returns changeset error for invalid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      invalid_attrs = %{description: nil}

      assert {:error, %Ecto.Changeset{}} =
               AcceptanceCriteriaRepository.update_criterion(criterion, invalid_attrs)
    end
  end

  describe "delete_criterion/1" do
    test "deletes criterion successfully" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, %Criterion{}} = AcceptanceCriteriaRepository.delete_criterion(criterion)

      assert is_nil(AcceptanceCriteriaRepository.get_criterion(scope, criterion.id))
    end

    test "returns deleted criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, deleted_criterion} = AcceptanceCriteriaRepository.delete_criterion(criterion)

      assert deleted_criterion.id == criterion.id
      assert deleted_criterion.description == criterion.description
    end
  end

  # Fixture helpers

  defp valid_criterion_attrs(scope, story, attrs \\ %{}) do
    Enum.into(attrs, %{
      description: "Test criterion description",
      story_id: story.id,
      project_id: scope.active_project.id,
      verified: false
    })
  end

  defp criterion_fixture(scope, story, attrs \\ %{}) do
    attrs = valid_criterion_attrs(scope, story, attrs)

    {:ok, criterion} = AcceptanceCriteriaRepository.create_criterion(attrs)

    criterion
  end
end
