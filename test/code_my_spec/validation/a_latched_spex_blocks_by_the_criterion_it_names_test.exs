defmodule CodeMySpec.Validation.ALatchedSpexBlocksByTheCriterionItNamesTest do
  @moduledoc """
  A red spex blocks when the criterion its file names is latched, whatever path
  that criterion once recorded.

  2026-10-05: `mix cms.stamp_spex` (66530d93d) renamed 1,417 spex files to
  `criterion_<number>_…` but ran against a copy of the dev database, so the
  live `criteria.spec_path` still named the old files: 1,319 of 1,550 latched
  criteria pointed at nothing on disk. A red spex in a renamed file matched no
  latched path, was advisory, and 22 latched criteria went red on main.

  Which criterion a file covers is the binding: its `spex "…", criterion: N`
  stamp, recorded as `files.criterion_number` and joined to `criteria.number`
  (`Files.SpecBinding`). A latched criterion no file on the copy names blocks
  too, so a binding that breaks is loud.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files.File, as: SpexFile
  alias CodeMySpec.Promotion
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Validation.Blocking

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    {:ok, criterion} =
      AcceptanceCriteria.create_criterion(scope, story, %{
        description: "a step reports its provider",
        # What the criterion recorded before the rename: no file is here now.
        spec_path: "test/spex/#{story.id}_old_name/criterion_#{story.id}0_old_spex.exs"
      })

    {:ok, criterion} = AcceptanceCriteria.latch_criterion(scope, criterion)

    path =
      "test/spex/#{story.number}_steps/criterion_#{criterion.number}_a_step_reports_its_provider_spex.exs"

    %{scope: scope, story: story, criterion: criterion, path: path}
  end

  defp bound(ctx, number) do
    {:ok, _file} =
      %SpexFile{}
      |> SpexFile.changeset(%{
        path: ctx.path,
        role: :bdd_spec,
        criterion_number: number,
        story_id: ctx.story.id,
        project_id: ctx.scope.active_project_id,
        working_copy_id: ctx.scope.active_working_copy_id
      })
      |> Repo.insert()

    :ok
  end

  defp red(ctx),
    do: problem_fixture(ctx.scope, %{source: "spex", severity: :error, file_path: ctx.path})

  test "a red spex in the file its latched criterion's number names blocks", ctx do
    :ok = bound(ctx, ctx.criterion.number)
    problem = red(ctx)

    assert [^problem] = Blocking.enforceable(ctx.scope, [problem]),
           "the criterion is latched and its file is red; the stale spec_path it " <>
             "recorded is not where the file is"
  end

  test "a red spex whose file names an unlatched criterion does not block", ctx do
    {:ok, other} =
      AcceptanceCriteria.create_criterion(ctx.scope, ctx.story, %{description: "new"})

    :ok = bound(ctx, other.number)
    problem = red(ctx)

    assert [] = Blocking.enforceable(ctx.scope, [problem])
  end

  test "a latched criterion no spex file names is a blocking problem", ctx do
    {:ok, other} =
      AcceptanceCriteria.create_criterion(ctx.scope, ctx.story, %{description: "other"})

    :ok = bound(ctx, other.number)

    assert [unbound] = Blocking.unbound_latched(ctx.scope)
    assert unbound.source == "spex"
    assert unbound.message =~ "criterion #{ctx.criterion.number}"

    assert Enum.any?(Promotion.blocking_problems(ctx.scope), &(&1.message == unbound.message)),
           "the gate did not count it"
  end

  test "a latched criterion a spex file names is not", ctx do
    :ok = bound(ctx, ctx.criterion.number)

    assert [] = Blocking.unbound_latched(ctx.scope)
  end

  # A copy with no spex rows at all has not been synced: nothing was observed
  # missing (story 1091's spex, whose gate copy never syncs files, 2026-10-05).
  test "a copy that has synced no spex says nothing about latched criteria", ctx do
    assert [] = Blocking.unbound_latched(ctx.scope)
  end
end
