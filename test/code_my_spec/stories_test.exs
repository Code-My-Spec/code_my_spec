defmodule CodeMySpec.StoriesTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Stories

  describe "stories" do
    import CodeMySpec.UsersFixtures
    import CodeMySpec.StoriesFixtures
    import CodeMySpec.ComponentsFixtures

    test "update_story/3 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)

      assert_raise MatchError, fn ->
        Stories.update_story(other_scope, story, %{})
      end
    end

    test "retire_story/2 with invalid scope raises" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      assert_raise MatchError, fn -> Stories.retire_story(other_scope, story) end
    end

    test "change_story/2 returns a story changeset" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      assert %Ecto.Changeset{} = Stories.change_story(scope, story)
    end

    test "set_story_component/3 updates story with component" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      assert {:ok, updated_story} = Stories.set_story_component(scope, story, component.id)
      assert updated_story.component_id == component.id
    end

    test "clear_story_component/2 removes component from story" do
      scope = full_scope_fixture()
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})

      assert {:ok, updated_story} = Stories.clear_story_component(scope, story)
      assert is_nil(updated_story.component_id)
    end

    test "set_story_component/3 with invalid scope returns unauthorized error" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      story = story_fixture(scope)
      component = component_fixture(scope)

      assert {:error, :unauthorized} =
               Stories.set_story_component(other_scope, story, component.id)
    end

    test "clear_story_component/2 with invalid scope returns unauthorized error" do
      scope = full_scope_fixture()
      other_scope = full_scope_fixture()
      component = component_fixture(scope)
      story = story_fixture(scope, %{component_id: component.id})

      assert {:error, :unauthorized} = Stories.clear_story_component(other_scope, story)
    end

    test "list_unsatisfied_stories/1 returns stories without components" do
      scope = full_scope_fixture()
      component = component_fixture(scope)

      satisfied_story = story_fixture(scope, %{component_id: component.id})
      unsatisfied_story = story_fixture(scope, %{component_id: nil})

      unsatisfied = Stories.list_unsatisfied_stories(scope)

      assert length(unsatisfied) == 1
      assert hd(unsatisfied).id == unsatisfied_story.id
      refute Enum.any?(unsatisfied, fn s -> s.id == satisfied_story.id end)
    end
  end

  # e1174640: a promote latches and stamps the one story it names.
  describe "mark_story_promoted/4" do
    import CodeMySpec.UsersFixtures
    import CodeMySpec.StoriesFixtures

    test "latches and stamps the story in one write, touching no other" do
      scope = full_scope_fixture()
      story = story_fixture(scope)
      other = story_fixture(scope, %{specs_ready: true})

      assert {:ok, stamped} =
               Stories.mark_story_promoted(scope, story, "2.0.11",
                 at: DateTime.utc_now(),
                 commit: "abc"
               )

      assert stamped.specs_ready == true
      assert stamped.promoted_version == "2.0.11"
      assert stamped.specs_ready_commit == "abc"
      assert stamped.promoted_working_copy_id == scope.active_working_copy_id
      assert stamped.promoted_at == stamped.specs_ready_at
      {:ok, revised} = Stories.set_specs_ready(scope, stamped, false)
      later = DateTime.add(stamped.promoted_at, 86_400, :second)

      {:ok, promoted_again} =
        Stories.mark_story_promoted(scope, revised, "2.0.12",
          at: later,
          working_copy_id: Ecto.UUID.generate()
        )

      assert promoted_again.promoted_working_copy_id == stamped.promoted_working_copy_id
      assert promoted_again.promoted_at == stamped.promoted_at
      assert Stories.get_story!(scope, other.id).promoted_version == nil
    end

    test "keeps the version an already-promoted story was first stamped with" do
      scope = full_scope_fixture()
      story = story_fixture(scope, %{promoted_version: "2.0.10"})

      assert {:ok, stamped} = Stories.mark_story_promoted(scope, story, "2.0.11")

      assert stamped.promoted_version == "2.0.10"
      assert stamped.specs_ready == true
    end

    test "latches without stamping when there is no version" do
      scope = full_scope_fixture()
      story = story_fixture(scope)

      assert {:ok, stamped} = Stories.mark_story_promoted(scope, story, nil)

      assert stamped.specs_ready == true
      assert stamped.promoted_version == nil
    end
  end
end
