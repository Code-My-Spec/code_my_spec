defmodule CodeMySpec.AcceptanceCriteriaTest do
  use CodeMySpec.DataCase

  alias CodeMySpec.AcceptanceCriteria

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  describe "subscribe_criteria/1" do
    test "subscribes to account-scoped criteria events" do
      scope = full_scope_fixture()
      assert :ok = AcceptanceCriteria.subscribe_criteria(scope)
    end

    test "receives {:created, criterion}, {:updated, criterion}, {:deleted, criterion} messages" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      AcceptanceCriteria.subscribe_criteria(scope)

      # Test created event
      {:ok, created_criterion} =
        AcceptanceCriteria.create_criterion(scope, story, %{
          description: "Test criterion for event"
        })

      assert_receive {:created, received_criterion}
      assert received_criterion.id == created_criterion.id

      # Test updated event
      {:ok, updated_criterion} =
        AcceptanceCriteria.update_criterion(scope, created_criterion, %{
          description: "Updated description"
        })

      assert_receive {:updated, received_updated}
      assert received_updated.id == updated_criterion.id

      # Test deleted event
      {:ok, deleted_criterion} = AcceptanceCriteria.delete_criterion(scope, updated_criterion)

      assert_receive {:deleted, received_deleted}
      assert received_deleted.id == deleted_criterion.id
    end
  end

  describe "create_criterion/3" do
    test "creates criterion with valid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      attrs = valid_criterion_attrs(%{description: "Valid test criterion"})

      assert {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, attrs)
      assert criterion.description == "Valid test criterion"
      assert criterion.verified == false
      assert is_nil(criterion.verified_at)
    end

    test "sets story_id from provided story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      attrs = valid_criterion_attrs()

      assert {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, attrs)
      assert criterion.story_id == story.id
    end

    test "sets project_id from scope" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      attrs = valid_criterion_attrs()

      assert {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, attrs)
      assert criterion.project_id == scope.active_project.id
    end

    test "broadcasts created event on success" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      AcceptanceCriteria.subscribe_criteria(scope)

      attrs = valid_criterion_attrs()

      assert {:ok, criterion} = AcceptanceCriteria.create_criterion(scope, story, attrs)

      assert_receive {:created, received_criterion}
      assert received_criterion.id == criterion.id
    end

    test "returns changeset error for invalid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      invalid_attrs = invalid_criterion_attrs()

      assert {:error, %Ecto.Changeset{}} =
               AcceptanceCriteria.create_criterion(scope, story, invalid_attrs)
    end

    test "validates required fields (description)" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:error, changeset} =
               AcceptanceCriteria.create_criterion(scope, story, %{description: nil})

      assert %{description: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "update_criterion/3" do
    test "updates criterion with valid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      update_attrs = %{description: "Updated criterion description"}

      assert {:ok, updated} = AcceptanceCriteria.update_criterion(scope, criterion, update_attrs)
      assert updated.description == "Updated criterion description"
      assert updated.id == criterion.id
    end

    test "verifies ownership via project_id" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert_raise MatchError, fn ->
        AcceptanceCriteria.update_criterion(other_scope, criterion, %{
          description: "Attempt update"
        })
      end
    end

    test "broadcasts updated event on success" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      AcceptanceCriteria.subscribe_criteria(scope)

      assert {:ok, updated} =
               AcceptanceCriteria.update_criterion(scope, criterion, %{
                 description: "Updated description"
               })

      assert_receive {:updated, received_criterion}
      assert received_criterion.id == updated.id
    end

    test "returns changeset error for invalid attributes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:error, %Ecto.Changeset{}} =
               AcceptanceCriteria.update_criterion(scope, criterion, %{
                 description: nil
               })
    end
  end

  describe "delete_criterion/2" do
    test "deletes criterion successfully" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, deleted} = AcceptanceCriteria.delete_criterion(scope, criterion)
      assert deleted.id == criterion.id
      assert is_nil(AcceptanceCriteria.get_criterion(scope, criterion.id))
    end

    test "verifies ownership via project_id" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert_raise MatchError, fn ->
        AcceptanceCriteria.delete_criterion(other_scope, criterion)
      end
    end

    test "broadcasts deleted event on success" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      AcceptanceCriteria.subscribe_criteria(scope)

      assert {:ok, deleted} = AcceptanceCriteria.delete_criterion(scope, criterion)

      assert_receive {:deleted, received_criterion}
      assert received_criterion.id == deleted.id
    end
  end

  describe "change_criterion/3" do
    test "returns changeset for valid criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      changeset =
        AcceptanceCriteria.change_criterion(scope, criterion, %{description: "New description"})

      assert %Ecto.Changeset{} = changeset
      assert changeset.data.id == criterion.id
    end

    test "validates ownership before returning changeset" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert_raise MatchError, fn ->
        AcceptanceCriteria.change_criterion(other_scope, criterion, %{
          description: "Attempt change"
        })
      end
    end

    test "does not persist changes" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)
      original_description = criterion.description

      AcceptanceCriteria.change_criterion(scope, criterion, %{
        description: "Different description"
      })

      reloaded = AcceptanceCriteria.get_criterion(scope, criterion.id)
      assert reloaded.description == original_description
    end
  end

  describe "mark_verified/2" do
    test "marks criterion as verified" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert criterion.verified == false
      assert is_nil(criterion.verified_at)

      assert {:ok, verified} = AcceptanceCriteria.mark_verified(scope, criterion)
      assert verified.verified == true
    end

    test "sets verified_at timestamp" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert {:ok, verified} = AcceptanceCriteria.mark_verified(scope, criterion)

      assert verified.verified_at != nil
      # Check that timestamp is within the last 5 seconds (reasonable for test execution)
      assert DateTime.diff(DateTime.utc_now(), verified.verified_at) < 5
    end

    test "broadcasts updated event on success" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      AcceptanceCriteria.subscribe_criteria(scope)

      assert {:ok, verified} = AcceptanceCriteria.mark_verified(scope, criterion)

      assert_receive {:updated, received_criterion}
      assert received_criterion.id == verified.id
      assert received_criterion.verified == true
    end

    test "idempotent when already verified" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      {:ok, first_verified} = AcceptanceCriteria.mark_verified(scope, criterion)
      {:ok, second_verified} = AcceptanceCriteria.mark_verified(scope, first_verified)

      assert second_verified.verified == true
      assert second_verified.id == first_verified.id
    end
  end

  describe "mark_unverified/2" do
    test "marks criterion as unverified" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = verified_criterion_fixture(scope, story)

      assert criterion.verified == true

      assert {:ok, unverified} = AcceptanceCriteria.mark_unverified(scope, criterion)
      assert unverified.verified == false
    end

    test "clears verified_at timestamp" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = verified_criterion_fixture(scope, story)

      assert criterion.verified_at != nil

      assert {:ok, unverified} = AcceptanceCriteria.mark_unverified(scope, criterion)
      assert is_nil(unverified.verified_at)
    end

    test "broadcasts updated event on success" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = verified_criterion_fixture(scope, story)

      AcceptanceCriteria.subscribe_criteria(scope)

      assert {:ok, unverified} = AcceptanceCriteria.mark_unverified(scope, criterion)

      assert_receive {:updated, received_criterion}
      assert received_criterion.id == unverified.id
      assert received_criterion.verified == false
    end

    test "idempotent when already unverified" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      assert criterion.verified == false

      {:ok, first_unverified} = AcceptanceCriteria.mark_unverified(scope, criterion)
      {:ok, second_unverified} = AcceptanceCriteria.mark_unverified(scope, first_unverified)

      assert second_unverified.verified == false
      assert second_unverified.id == first_unverified.id
    end
  end

  describe "import_from_strings/3" do
    test "creates criterion for each string" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      strings = [
        "First acceptance criterion",
        "Second acceptance criterion",
        "Third acceptance criterion"
      ]

      assert {:ok, criteria} = AcceptanceCriteria.import_from_strings(scope, story, strings)

      assert length(criteria) == 3
      assert Enum.at(criteria, 0).description == "First acceptance criterion"
      assert Enum.at(criteria, 1).description == "Second acceptance criterion"
      assert Enum.at(criteria, 2).description == "Third acceptance criterion"

      Enum.each(criteria, fn criterion ->
        assert criterion.story_id == story.id
        assert criterion.project_id == scope.active_project.id
      end)
    end

    test "handles empty list gracefully" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:ok, criteria} = AcceptanceCriteria.import_from_strings(scope, story, [])
      assert criteria == []
    end

    test "broadcasts created event for each criterion" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      AcceptanceCriteria.subscribe_criteria(scope)

      strings = ["First criterion", "Second criterion"]

      assert {:ok, criteria} = AcceptanceCriteria.import_from_strings(scope, story, strings)

      assert_receive {:created, first_criterion}
      assert_receive {:created, second_criterion}

      criterion_ids = Enum.map(criteria, & &1.id)
      assert first_criterion.id in criterion_ids
      assert second_criterion.id in criterion_ids
    end
  end

  describe "export_to_strings/2" do
    test "returns descriptions in creation order" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      # Create criteria in specific order
      criterion_fixture(scope, story, %{description: "First criterion"})
      criterion_fixture(scope, story, %{description: "Second criterion"})
      criterion_fixture(scope, story, %{description: "Third criterion"})

      strings = AcceptanceCriteria.export_to_strings(scope, story)

      assert strings == [
               "First criterion",
               "Second criterion",
               "Third criterion"
             ]
    end

    test "returns empty list when story has no criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      strings = AcceptanceCriteria.export_to_strings(scope, story)

      assert strings == []
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      story_in_scope = story_fixture(scope)
      story_in_other_scope = story_fixture(other_scope)

      criterion_fixture(scope, story_in_scope, %{description: "Scoped criterion"})

      criterion_fixture(other_scope, story_in_other_scope, %{
        description: "Other scoped criterion"
      })

      strings = AcceptanceCriteria.export_to_strings(scope, story_in_scope)

      assert strings == ["Scoped criterion"]
      assert length(strings) == 1
    end
  end

  describe "list_story_criteria/2" do
    test "returns all criteria for a story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criterion1 = criterion_fixture(scope, story, %{description: "First"})
      criterion2 = criterion_fixture(scope, story, %{description: "Second"})

      criteria = AcceptanceCriteria.list_story_criteria(scope, story.id)

      assert length(criteria) == 2
      criterion_ids = Enum.map(criteria, & &1.id)
      assert criterion1.id in criterion_ids
      assert criterion2.id in criterion_ids
    end

    test "returns empty list for story with no criteria" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      criteria = AcceptanceCriteria.list_story_criteria(scope, story.id)

      assert criteria == []
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      story = story_fixture(scope)
      other_story = story_fixture(other_scope)

      criterion_fixture(scope, story)
      criterion_fixture(other_scope, other_story)

      criteria = AcceptanceCriteria.list_story_criteria(scope, story.id)

      assert length(criteria) == 1
      assert hd(criteria).story_id == story.id
    end
  end

  describe "get_criterion!/2" do
    test "returns criterion by id" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      found = AcceptanceCriteria.get_criterion!(scope, criterion.id)

      assert found.id == criterion.id
      assert found.description == criterion.description
    end

    test "raises when criterion not found" do
      scope = full_scope_fixture()

      assert_raise Ecto.NoResultsError, fn ->
        AcceptanceCriteria.get_criterion!(scope, 999_999)
      end
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      story = story_fixture(other_scope)
      criterion = criterion_fixture(other_scope, story)

      assert_raise Ecto.NoResultsError, fn ->
        AcceptanceCriteria.get_criterion!(scope, criterion.id)
      end
    end
  end

  describe "get_criterion/2" do
    test "returns criterion by id" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      criterion = criterion_fixture(scope, story)

      found = AcceptanceCriteria.get_criterion(scope, criterion.id)

      assert found.id == criterion.id
      assert found.description == criterion.description
    end

    test "returns nil when criterion not found" do
      scope = full_scope_fixture()

      assert is_nil(AcceptanceCriteria.get_criterion(scope, 999_999))
    end

    test "respects project scope" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      story = story_fixture(other_scope)
      criterion = criterion_fixture(other_scope, story)

      assert is_nil(AcceptanceCriteria.get_criterion(scope, criterion.id))
    end
  end
end
