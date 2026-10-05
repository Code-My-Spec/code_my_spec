defmodule CodeMySpec.Promotion.ACriterionLatchesByTheSpexThatNamesItTest do
  @moduledoc """
  A promote latches a criterion whose spex went green, and which spex is a
  criterion's is the binding (`Files.SpecBinding`: the file's `criterion: N`
  stamp joined to `criteria.number`), never a recorded or derived path.

  2026-10-05: after a rename, latched criteria recorded paths no file was at.
  A criterion's own renamed file could be red while its recorded path was
  "not failing", and it latched.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files
  alias CodeMySpec.Promotion
  alias CodeMySpec.Stories.AcceptanceCriteria

  setup do
    scope = full_scope_fixture()
    story = story_fixture(scope)

    criteria =
      for name <- ~w(green red unbound) do
        {:ok, criterion} =
          AcceptanceCriteria.create_criterion(scope, story, %{
            description: name,
            spec_path: "test/spex/old/criterion_0_#{name}_spex.exs"
          })

        {name, criterion}
      end
      |> Map.new()

    for name <- ~w(green red), do: bind(scope, story, criteria[name], path(story, name))

    problem_fixture(scope, %{
      source: "spex",
      severity: :error,
      file_path: path(story, "red")
    })

    %{scope: scope, story: story, criteria: criteria}
  end

  defp path(story, name), do: "test/spex/#{story.number}_s/criterion_#{name}_spex.exs"

  defp bind(scope, story, criterion, path) do
    Files.upsert_files(scope, [
      %{
        path: path,
        role: :bdd_spec,
        story_id: story.id,
        criterion_number: criterion.number,
        valid: true,
        mtime: DateTime.utc_now()
      }
    ])
  end

  defp latched?(ctx, name),
    do: not is_nil(AcceptanceCriteria.get_criterion!(ctx.scope, ctx.criteria[name].id).latched_at)

  test "a promote latches the criterion whose named spex is green, and only that one", ctx do
    assert :ok = Promotion.story_spex_check(ctx.scope, ctx.story)

    assert latched?(ctx, "green")

    refute latched?(ctx, "red"),
           "its own file is red; the path it recorded is not where its file is"

    refute latched?(ctx, "unbound"), "no spex names it, so nothing of it went green"
  end
end
