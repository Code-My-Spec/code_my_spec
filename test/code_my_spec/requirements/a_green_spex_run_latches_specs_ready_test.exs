defmodule CodeMySpec.Requirements.AGreenSpexRunLatchesSpecsReadyTest do
  @moduledoc """
  A green spex run sets `specs_ready` for the stories it proves.

  `Stories.set_specs_ready/4` has always said this is how the latch moves —
  "the specs-passing gate sets it on a fresh green run, the chain-restart path
  clears it when the story's BDD specs are rewritten, and the user flips it by
  hand from the project UI." Two of those three existed. The only writer of
  `true` was the UI toggle, so a story whose specs went green stayed false until
  somebody clicked it.

  That is the last human step in an otherwise unattended run, and it is where the
  math project stopped on 2026-09-22: two stories, specs and implementation both
  written by the fleet, zero failures on a fresh run, and `bdd_specs_passing`
  false on both because nothing set the latch.

  ## The failure this must not repeat

  Both earlier attempts matched a failing spec to its story by parsing the spec
  directory's name, and those are prefixed from `story.number` in some places
  and `story.id` in others. The comparison matched nothing for whichever
  convention it was not written for, the gate read "no failing specs", and it
  latched on red — 47 of 61 stories on Broken Oaths carrying `specs_ready: true`
  over 127 red specs. The second test here is that case: a story with a failing
  spec must stay false.

  `Files.bdd_spec_story_id_by_path/1` is why this one can be right. The linkage
  is resolved at sync time from the spec itself, so no naming convention has to
  hold.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Files
  alias CodeMySpec.Problems
  alias CodeMySpec.Requirements.SpecsReadyLatch
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  # `apply_up_to_analysis/1` stops one step short of the readiness transition,
  # so it leaves a story with real BDD spec files on disk and `specs_ready`
  # still false — which is exactly the state this is about.
  setup ctx do
    ctx = FullSatisfactionFixtures.apply_up_to_analysis(ctx)

    refute Stories.get_story(ctx.scope, ctx.story.id).specs_ready == true,
           "the premise is a story whose specs are written and not yet latched"

    ctx
  end

  defp spec_paths(ctx, story) do
    ctx.scope
    |> Files.list_story_files(story.id)
    |> Enum.filter(&(&1.role == :bdd_spec))
    |> Enum.map(& &1.path)
  end

  defp fail_spec(ctx, path) do
    {:ok, _} =
      Problems.create_problems(ctx.scope, [
        %{
          severity: :error,
          source: "spex",
          source_type: :test,
          file_path: path,
          message: "criterion failed",
          category: "spex_failure",
          project_id: ctx.scope.active_project_id,
          working_copy_id: ctx.scope.active_working_copy_id
        }
      ])

    :ok
  end

  defp reload(ctx, story), do: Stories.get_story(ctx.scope, story.id)

  test "a story whose specs are all green is latched", ctx do
    assert spec_paths(ctx, ctx.story) != [], "the fixture must leave spec files behind"

    assert ctx.story.id in SpecsReadyLatch.settle(ctx.scope)

    assert reload(ctx, ctx.story).specs_ready == true,
           """
           A story with BDD specs and no failures was left unlatched.

           Nothing else sets this: the only other writer of `true` is the UI
           toggle, so leaving it false means a person has to click before
           `bdd_specs_passing` can go green.
           """
  end

  test "a story with a failing spec is not latched", ctx do
    [path | _] = spec_paths(ctx, ctx.story)
    :ok = fail_spec(ctx, path)

    refute ctx.story.id in SpecsReadyLatch.settle(ctx.scope)

    refute reload(ctx, ctx.story).specs_ready == true,
           """
           A story was latched over its own failing spec.

           This is the Broken Oaths failure exactly: the gate decided the story
           had no failing specs, latched, and `bdd_specs_passing` stopped being
           actionable for work that was never done.
           """
  end
end
