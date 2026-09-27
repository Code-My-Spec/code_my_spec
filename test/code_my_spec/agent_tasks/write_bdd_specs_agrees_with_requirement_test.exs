defmodule CodeMySpec.AgentTasks.WriteBddSpecsAgreesWithRequirementTest do
  @moduledoc """
  `evaluate/2` never passes while `bdd_specs_exist` is unsatisfied.

  Issue 94327fe2: criteria renumbered under their spec files, the files stayed
  at the recorded paths but no longer belonged to the story, the evaluator
  passed on path existence alone and `get_next_requirement` re-offered forever.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.BddSpecs
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Requirements.RequirementCalculator
  alias CodeMySpec.Requirements.RequirementDefinitionData
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies

  @valid_spec """
  defmodule MyAppSpex.ExampleSpex do
    use MyAppSpex.Case

    spex "example" do
      scenario "happy path" do
        given_ "setup", _context do
          :ok
        end

        when_ "action", _context do
          :ok
        end

        then_ "outcome", _context do
          :ok
        end
      end
    end
  end
  """

  setup do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "mine", device: device_fixture(scope))
    scope = %{scope | active_working_copy_id: copy.id}

    story = story_fixture(scope, %{title: "Renumbered story"})
    other = story_fixture(scope, %{title: "Someone else's story"})

    %{scope: scope, story: Stories.get_story(scope, story.id), other: other}
  end

  defp claim_paths!(scope, story) do
    for criterion <- story.criteria do
      path = BddSpecs.spec_file_path(story, criterion)
      criterion |> Ecto.Changeset.change(spec_path: path) |> Repo.update!()
    end

    Stories.get_story(scope, story.id)
  end

  defp record!(scope, story, story_id) do
    Files.upsert_files(
      scope,
      Enum.map(story.criteria, fn criterion ->
        %{
          path: BddSpecs.spec_file_path(story, criterion),
          role: :bdd_spec,
          story_id: story_id,
          valid: true,
          mtime: DateTime.utc_now(),
          size: 1
        }
      end)
    )
  end

  # The requirement as the stop hook's `Evaluator` computes it for one story.
  defp requirement_satisfied?(scope, story) do
    definition =
      Enum.find(RequirementDefinitionData.story_requirements(), &(&1.name == "bdd_specs_exist"))

    files = Files.list_story_files(scope, story.id)
    RequirementCalculator.compute_one(scope, story, definition, files).satisfied
  end

  test "files at the claimed paths attributed to no story do not pass", ctx do
    story = claim_paths!(ctx.scope, ctx.story)
    record!(ctx.scope, story, nil)

    refute requirement_satisfied?(ctx.scope, story)

    assert {:ok, :invalid, message} = WriteBddSpecs.evaluate(ctx.scope, %{story_id: story.id})
    assert message =~ "attributed to no story"
  end

  test "files at the claimed paths attributed to another story do not pass", ctx do
    story = claim_paths!(ctx.scope, ctx.story)
    record!(ctx.scope, story, ctx.other.id)

    refute requirement_satisfied?(ctx.scope, story)

    assert {:ok, :invalid, message} = WriteBddSpecs.evaluate(ctx.scope, %{story_id: story.id})
    assert message =~ "attributed to story #{ctx.other.id}"
  end

  test "a criterion with no recorded spec_path does not pass on the derived path", ctx do
    record!(ctx.scope, ctx.story, ctx.story.id)

    refute requirement_satisfied?(ctx.scope, ctx.story)

    assert {:ok, :invalid, message} =
             WriteBddSpecs.evaluate(ctx.scope, %{story_id: ctx.story.id})

    assert message =~ "no spec_path is recorded"
  end

  @tag :tmp_dir
  test "a valid spec on disk that no working copy has reported does not pass", ctx do
    story = claim_paths!(ctx.scope, ctx.story)
    scope = %{ctx.scope | environment: Environment.new(:local, ctx.tmp_dir)}

    for criterion <- story.criteria do
      path = Path.join(ctx.tmp_dir, criterion.spec_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, @valid_spec)
    end

    refute requirement_satisfied?(scope, story)

    assert {:ok, :invalid, message} = WriteBddSpecs.evaluate(scope, %{story_id: story.id})
    assert message =~ "no working copy has reported it"
  end

  test "claimed paths attributed to this story pass both", ctx do
    story = claim_paths!(ctx.scope, ctx.story)
    record!(ctx.scope, story, story.id)

    assert requirement_satisfied?(ctx.scope, story)
    assert {:ok, :valid} = WriteBddSpecs.evaluate(ctx.scope, %{story_id: story.id})
  end
end
