defmodule CodeMySpec.Requirements.BandsTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.StoriesFixtures

  import CodeMySpec.AcceptanceCriteriaFixtures

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.{Bands, GraphStore, Node}
  alias CodeMySpec.Stories.AcceptanceCriteria

  test "the project's gates after stories join are the QA journey" do
    late = Bands.late_project_names()

    assert MapSet.member?(late, "qa_journey_plan")
    assert MapSet.member?(late, "qa_journey_execute")
    refute MapSet.member?(late, "work_dispatched")
    refute MapSet.member?(late, "personas_complete")
  end

  test "a story's steps run prerequisites first" do
    steps = Bands.story_step_names()
    position = &Enum.find_index(steps, fn name -> name == &1 end)

    assert hd(steps) == "component_linked"
    assert position.("three_amigos_complete") < position.("bdd_specs_exist")
    assert position.("bdd_specs_exist") < position.("ready_for_qa")
    assert position.("ready_for_qa") < position.("qa_complete")
    assert position.("story_promoted") < position.("deploy")
  end

  describe "read/1 — done is every step satisfied, not promoted_at" do
    # A projected project, its verdicts seeded below: one never projected has no
    # graph to read.
    setup do
      scope = full_scope_fixture()
      :ok = GraphStore.write_topology(scope.active_project_id, "seeded", [], [])
      %{scope: scope}
    end

    # A story's steps as the graph reads them: record verdicts stored once per
    # project, and `bdd_specs_exist` from the copy's files — a criterion and a
    # spex naming it.
    defp seed_steps(story, satisfied_names, scope) do
      for name <- Bands.story_step_names(), name in GraphStore.project_wide_names() do
        %Node{}
        |> Ecto.put_meta(source: "project_requirements")
        |> Node.changeset(%{
          name: name,
          description: name,
          story_id: story.id,
          satisfied: name in satisfied_names
        })
        |> Repo.insert!()
      end

      cover(story, scope, "bdd_specs_exist" in satisfied_names)
    end

    defp cover(_story, _scope, false), do: :ok

    defp cover(story, scope, true) do
      criterion_fixture(scope, story)

      for criterion <- AcceptanceCriteria.list_story_criteria(scope, story.id) do
        Repo.insert!(%FileRecord{
          project_id: scope.active_project_id,
          working_copy_id: scope.active_working_copy_id,
          path: "test/spex/#{story.number}_story/criterion_#{criterion.number}_spex.exs",
          role: :bdd_spec,
          valid: true,
          validation_errors: %{"data" => %{"criterion" => criterion.number}},
          criterion_number: criterion.number
        })
      end
    end

    test "a promoted story with an unsatisfied step still shows on the chart, not as done", %{
      scope: scope
    } do
      story = story_fixture(scope)
      seed_steps(story, Bands.story_step_names() -- ["qa_complete"], scope)

      story
      |> Ecto.Changeset.change(promoted_at: DateTime.utc_now())
      |> Repo.update!()

      bands = Bands.read(scope)

      assert Enum.any?(bands.stories, &(&1.id == story.id)),
             "a promoted story with outstanding requirements (re-certification, QA, a " <>
               "submitted fix) has to stay on the chart rather than vanish because it is promoted"
    end

    test "an unpromoted story whose requirements are all satisfied is done, off the chart", %{
      scope: scope
    } do
      story = story_fixture(scope)
      seed_steps(story, Bands.story_step_names(), scope)

      bands = Bands.read(scope)

      refute Enum.any?(bands.stories, &(&1.id == story.id)),
             "a story whose requirements are all satisfied has to come off the chart " <>
               "regardless of promoted_at"

      assert bands.story_counts.done >= 1
    end

    test "the chart and the done count agree: as many done stories as the count says", %{
      scope: scope
    } do
      done_story = story_fixture(scope)
      seed_steps(done_story, Bands.story_step_names(), scope)

      working_story = story_fixture(scope)
      seed_steps(working_story, [], scope)

      bands = Bands.read(scope)

      assert Enum.any?(bands.stories, &(&1.id == working_story.id))
      refute Enum.any?(bands.stories, &(&1.id == done_story.id))
      assert bands.story_counts.done == 1
    end
  end
end
