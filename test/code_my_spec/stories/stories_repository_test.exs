defmodule CodeMySpec.Stories.StoriesRepositoryTest do
  use CodeMySpec.DataCase

  alias CodeMySpec.Stories.StoriesRepository

  describe "stories" do
    alias CodeMySpec.Stories.Story

    import CodeMySpec.UsersFixtures
    import CodeMySpec.StoriesFixtures

    @invalid_attrs %{
      status: nil,
      description: nil,
      title: nil,
      acceptance_criteria: nil,
      locked_at: nil,
      lock_expires_at: nil
    }

    test "list_stories/1 returns all scoped stories" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      other_story = story_fixture(other_scope)
      assert StoriesRepository.list_stories(scope) == [story]
      assert StoriesRepository.list_stories(other_scope) == [other_story]
    end

    test "list_project_stories/1 returns all project stories" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      other_story = story_fixture(other_scope)

      {:ok, stories} = StoriesRepository.list_project_stories(scope)
      assert length(stories) == 1
      assert hd(stories).id == story.id

      {:ok, other_stories} = StoriesRepository.list_project_stories(other_scope)
      assert length(other_stories) == 1
      assert hd(other_stories).id == other_story.id
    end

    test "list_unsatisfied_stories/1 returns only stories without components" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      # Need to import ComponentsFixtures for component_fixture
      import CodeMySpec.ComponentsFixtures
      component = component_fixture(scope)

      # Create stories with and without components in same project
      satisfied_story = story_fixture(scope, %{component_id: component.id})
      unsatisfied_story1 = story_fixture(scope, %{component_id: nil})
      unsatisfied_story2 = story_fixture(scope)

      # Story in different project should not be included
      _other_unsatisfied = story_fixture(other_scope, %{component_id: nil})

      results = StoriesRepository.list_unsatisfied_stories(scope)

      assert length(results) == 2
      story_ids = Enum.map(results, & &1.id)
      assert unsatisfied_story1.id in story_ids
      assert unsatisfied_story2.id in story_ids
      refute satisfied_story.id in story_ids
    end

    test "get_story!/2 returns the story with given id" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      assert StoriesRepository.get_story!(scope, story.id) == story

      assert_raise Ecto.NoResultsError, fn ->
        StoriesRepository.get_story!(other_scope, story.id)
      end
    end

    test "create_story/2 with valid data creates a story" do
      valid_attrs = %{
        status: :in_progress,
        description: "some description",
        title: title = Faker.Lorem.word(),
        acceptance_criteria: ["option1", "option2"],
        locked_at: ~U[2025-07-17 12:48:00Z],
        lock_expires_at: ~U[2025-07-17 12:48:00Z]
      }

      scope = full_scope_fixture()

      assert {:ok, %Story{} = story} = StoriesRepository.create_story(scope, valid_attrs)
      assert story.status == :in_progress
      assert story.description == "some description"
      assert story.title == title
      assert story.acceptance_criteria == ["option1", "option2"]
      assert story.locked_at == ~U[2025-07-17 12:48:00Z]
      assert story.lock_expires_at == ~U[2025-07-17 12:48:00Z]
      assert story.account_id == scope.active_account.id
    end

    test "create_story/2 with invalid data returns error changeset" do
      scope = full_scope_fixture()
      assert {:error, %Ecto.Changeset{}} = StoriesRepository.create_story(scope, @invalid_attrs)
    end

    test "update_story/3 with valid data updates the story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      title = Faker.Lorem.word()

      update_attrs = %{
        status: :completed,
        description: "some updated description",
        title: title,
        acceptance_criteria: ["option1"],
        locked_at: ~U[2025-07-18 12:48:00Z],
        lock_expires_at: ~U[2025-07-18 12:48:00Z]
      }

      assert {:ok, %Story{} = story} = StoriesRepository.update_story(scope, story, update_attrs)
      assert story.status == :completed
      assert story.description == "some updated description"
      assert story.title == title
      assert story.acceptance_criteria == ["option1"]
      assert story.locked_at == ~U[2025-07-18 12:48:00Z]
      assert story.lock_expires_at == ~U[2025-07-18 12:48:00Z]
    end

    test "update_story/3 with invalid data returns error changeset" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:error, %Ecto.Changeset{}} =
               StoriesRepository.update_story(scope, story, @invalid_attrs)

      assert story == StoriesRepository.get_story!(scope, story.id)
    end

    test "delete_story/2 deletes the story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      assert {:ok, %Story{}} = StoriesRepository.delete_story(scope, story)
      assert_raise Ecto.NoResultsError, fn -> StoriesRepository.get_story!(scope, story.id) end
    end
  end

  describe "query functions" do
    alias CodeMySpec.Stories.Story

    import CodeMySpec.UsersFixtures
    import CodeMySpec.StoriesFixtures
    import CodeMySpec.ProjectsFixtures
    import Ecto.Query

    test "by_project/2 filters stories by project" do
      %{active_project: project} = scope = full_scope_fixture()
      %{active_project: other_project} = other_scope = full_scope_fixture()

      story1 = story_fixture(scope, %{project_id: project.id})
      _story2 = story_fixture(other_scope, %{project_id: other_project.id})

      results =
        Story
        |> StoriesRepository.by_project(project.id)
        |> Repo.all()

      assert length(results) == 1
      assert Enum.any?(results, fn s -> s.id == story1.id end)
    end

    test "by_status/2 filters stories by status" do
      scope = full_scope_fixture()

      story1 = story_fixture(scope, %{status: :in_progress})
      _story2 = story_fixture(scope, %{status: :completed})

      results =
        StoriesRepository.by_status(:in_progress)
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == story1.id
    end

    test "by_priority/2 filters stories by priority" do
      scope = full_scope_fixture()

      _story1 = story_fixture(scope, %{priority: 10})
      _story2 = story_fixture(scope, %{priority: 50})
      _story3 = story_fixture(scope, %{priority: 100})

      results =
        StoriesRepository.by_priority(50)
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 2
    end

    test "search_text/2 searches title and description" do
      scope = full_scope_fixture()

      story1 = story_fixture(scope, %{title: "User Login Feature"})
      story2 = story_fixture(scope, %{description: "Feature for user authentication"})
      _story3 = story_fixture(scope, %{title: "Bug Fix", description: "Fix payment issues"})

      results =
        StoriesRepository.search_text("Feature")
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 2
      assert Enum.any?(results, fn s -> s.id == story1.id end)
      assert Enum.any?(results, fn s -> s.id == story2.id end)
    end

    test "locked_by/2 filters stories by lock owner" do
      %{user: user} = scope = full_scope_fixture()
      %{user: other_user} = _other_scope = full_scope_fixture()

      story1 = story_fixture(scope, %{locked_by: user.id})
      _story2 = story_fixture(scope, %{locked_by: other_user.id})

      results =
        StoriesRepository.locked_by(user.id)
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == story1.id
    end

    test "lock_expired/1 filters expired locks" do
      %{user: user} = scope = full_scope_fixture()

      past_time = DateTime.utc_now() |> DateTime.add(-1, :hour)
      future_time = DateTime.utc_now() |> DateTime.add(1, :hour)

      story1 = story_fixture(scope, %{locked_by: user.id, lock_expires_at: past_time})
      _story2 = story_fixture(scope, %{locked_by: user.id, lock_expires_at: future_time})

      results =
        StoriesRepository.lock_expired()
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 1
      assert hd(results).id == story1.id
    end

    test "ordered_by_name/1 orders by title alphabetically" do
      scope = full_scope_fixture()

      _story1 = story_fixture(scope, %{title: "Zoo Story"})
      _story2 = story_fixture(scope, %{title: "Alpha Story"})
      _story3 = story_fixture(scope, %{title: "Beta Story"})

      results =
        StoriesRepository.ordered_by_name()
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 3
      assert Enum.at(results, 0).title == "Alpha Story"
      assert Enum.at(results, 1).title == "Beta Story"
      assert Enum.at(results, 2).title == "Zoo Story"
    end

    test "ordered_by_status/1 orders by status asc then inserted_at asc" do
      scope = full_scope_fixture()

      _story1 = story_fixture(scope, %{status: :completed})
      _story2 = story_fixture(scope, %{status: :in_progress})
      _story3 = story_fixture(scope, %{status: :dirty})

      results =
        StoriesRepository.ordered_by_status()
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(results) == 3
      assert Enum.at(results, 0).status == :completed
      assert Enum.at(results, 1).status == :dirty
      assert Enum.at(results, 2).status == :in_progress
    end

    test "paginate/3 limits and offsets results" do
      scope = full_scope_fixture()

      for _ <- 1..10 do
        story_fixture(scope)
      end

      page1 =
        Story
        |> StoriesRepository.paginate(1, 3)
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      page2 =
        Story
        |> StoriesRepository.paginate(2, 3)
        |> where([s], s.account_id == ^scope.active_account.id)
        |> Repo.all()

      assert length(page1) == 3
      assert length(page2) == 3
      assert page1 != page2
    end

    test "with_preloads/2 preloads associations" do
      scope = full_scope_fixture()
      project = project_fixture(scope)

      _story = story_fixture(scope, %{project_id: project.id})

      [result] =
        Story
        |> where([s], s.account_id == ^scope.active_account.id)
        |> StoriesRepository.with_preloads([:first_version])
        |> Repo.all()

      assert not is_nil(result.first_version)
    end
  end

  describe "lock management" do
    import CodeMySpec.UsersFixtures
    import CodeMySpec.StoriesFixtures

    test "acquire_lock/3 successfully locks unlocked story" do
      %{user: user} = scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)
      assert locked_story.locked_by == user.id
      assert not is_nil(locked_story.locked_at)
      assert not is_nil(locked_story.lock_expires_at)
      assert StoriesRepository.locked?(locked_story)
    end

    test "acquire_lock/3 fails when story already locked" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      story = story_fixture(scope)
      {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)

      assert {:error, :already_locked} =
               StoriesRepository.acquire_lock(other_scope, locked_story, 30)
    end

    test "release_lock/2 successfully releases lock" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)
      assert StoriesRepository.locked?(locked_story)

      assert {:ok, released_story} = StoriesRepository.release_lock(scope, locked_story)
      assert is_nil(released_story.locked_by)
      assert is_nil(released_story.locked_at)
      assert is_nil(released_story.lock_expires_at)
      refute StoriesRepository.locked?(released_story)
    end

    test "extend_lock/3 successfully extends lock for owner" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)
      original_expires_at = locked_story.lock_expires_at

      assert {:ok, extended_story} = StoriesRepository.extend_lock(scope, locked_story, 60)
      assert DateTime.compare(extended_story.lock_expires_at, original_expires_at) == :gt
    end

    test "extend_lock/3 fails when not lock owner" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()

      story = story_fixture(scope)
      {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)

      assert {:error, :not_lock_owner} =
               StoriesRepository.extend_lock(other_scope, locked_story, 60)
    end

    test "locked?/1 returns true for valid lock" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      refute StoriesRepository.locked?(story)
      {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)
      assert StoriesRepository.locked?(locked_story)
    end

    test "locked?/1 returns false for expired lock" do
      %{user: user} = scope = full_scope_fixture()

      past_time = DateTime.utc_now() |> DateTime.add(-1, :hour)

      story =
        story_fixture(scope, %{
          locked_by: user.id,
          locked_at: past_time,
          lock_expires_at: past_time
        })

      refute StoriesRepository.locked?(story)
    end

    test "lock_owner/1 returns lock owner user id" do
      %{user: user} = scope = full_scope_fixture()
      story = story_fixture(scope)

      assert is_nil(StoriesRepository.lock_owner(story))
      {:ok, locked_story} = StoriesRepository.acquire_lock(scope, story, 30)
      assert StoriesRepository.lock_owner(locked_story) == user.id
    end
  end

  describe "component assignment" do
    import CodeMySpec.UsersFixtures
    import CodeMySpec.StoriesFixtures
    import CodeMySpec.ComponentsFixtures

    test "set_story_component/3 successfully assigns component to story" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      assert {:ok, updated_story} =
               StoriesRepository.set_story_component(scope, story, component.id)

      assert updated_story.component_id == component.id
    end

    test "clear_story_component/2 successfully removes component assignment" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})

      assert {:ok, updated_story} = StoriesRepository.clear_story_component(scope, story)
      assert is_nil(updated_story.component_id)
    end

    test "set_story_component/3 creates audit trail" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      {:ok, _updated_story} = StoriesRepository.set_story_component(scope, story, component.id)

      versions = CodeMySpec.Repo.all(PaperTrail.Version)
      # Creation + component assignment
      assert length(versions) >= 2
    end

    test "clear_story_component/2 creates audit trail" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})

      {:ok, _updated_story} = StoriesRepository.clear_story_component(scope, story)

      versions = CodeMySpec.Repo.all(PaperTrail.Version)
      # Creation + component clearing
      assert length(versions) >= 2
    end
  end
end
