defmodule CodeMySpec.Requirements.ASweepSettlesOneProjectsRowsTest do
  @moduledoc """
  A sweep's default answers this project's rows and no other project's.

  A sweep is two statements. `put_verdicts/5` names each entity it corrects, so
  it cannot reach past the project that owns those ids. The default is the other
  half — "every row of this requirement the exceptions did not name" — and a set
  defined by what it excludes is only as narrow as its `WHERE` clause.

  ## Why eight vantages out of nine hid it

  The clause carried `working_copy_id IS NOT DISTINCT FROM $vantage`, and a
  working copy is a checkout of exactly one project. So wherever the vantage was
  a real copy, the sweep was scoped to one project by accident.

  `nil` is the vantage every project shares. It is not an edge case — it is what
  every reader that is not an agent resolves to, the browser included. There the
  predicate stopped scoping anything, and one project's drain answered every
  project's unscoped rows.

  ## Measured

  On dev, 2026-09-17, before the fix: this project's unscoped project row read
  `qa_journey_wallaby` satisfied, with the checker's own words — "4 file(s) at
  test/journeys/" — against a tree that has no such directory. The four files
  belong to another project's checkout; its drain wrote this project's answer.
  The same pass left 265 of this project's unscoped story rows disagreeing with
  the recompute.

  Over-satisfaction is the expensive direction: an agent is told the work is
  done and skips it.
  """
  use CodeMySpecSpex.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.ProjectsFixtures
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphStore
  alias CodeMySpec.Requirements.IncrementalGraph
  alias CodeMySpec.StoriesFixtures
  alias CodeMySpec.Users.Scope

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok
  end

  describe "the default half of a sweep" do
    test "leaves another project's rows at the same vantage alone", ctx do
      mine = unscoped(ctx.scope)
      theirs = unscoped(other_project_scope(ctx))

      # Both projects need rows at the unscoped vantage before either can be
      # wrongly written: a sweep settles rows and never creates them, so a
      # project nobody has computed for is untouched for a reason that has
      # nothing to do with scoping.
      StoriesFixtures.story_fixture(mine)
      StoriesFixtures.story_fixture(theirs)
      project(mine)
      project(theirs)

      before = verdicts(theirs, "bdd_specs_exist")

      assert before != [],
             "the other project has no rows to be overwritten, so this proves nothing"

      # The sweep under test: my project settles every story's `bdd_specs_exist`
      # to a default, naming no exceptions — which is the shape every project
      # requirement takes and the shape a fully-defaulted population takes.
      {:ok, _written} =
        GraphStore.sweep(mine, %{
          entity_type: "story",
          name: "bdd_specs_exist",
          default: true,
          default_details: %{status: "swept by another project"},
          except: []
        })

      assert verdicts(theirs, "bdd_specs_exist") == before,
             """
             A sweep run for one project rewrote another project's answers.

             The default half of a sweep names no entity — it is defined by what
             it excludes — so without a project predicate the rows it leaves over
             are every project's. `working_copy_id` covers for that wherever the
             vantage is a real checkout, because a checkout belongs to one
             project; `nil` is the vantage every project shares, and it is what
             every reader that is not an agent resolves to.

             before: #{inspect(before)}
             after:  #{inspect(verdicts(theirs, "bdd_specs_exist"))}
             """
    end

    test "still settles my own project's rows", ctx do
      mine = unscoped(ctx.scope)

      StoriesFixtures.story_fixture(mine)
      project(mine)

      {:ok, _} =
        GraphStore.sweep(mine, %{
          entity_type: "story",
          name: "bdd_specs_exist",
          default: true,
          default_details: %{status: "settled by my own sweep"},
          except: []
        })

      # Without this, a predicate that scoped nothing through and a predicate
      # that scoped correctly would be indistinguishable — the criterion above
      # passes for a sweep that writes no rows at all.
      assert Enum.all?(verdicts(mine, "bdd_specs_exist"), &match?({true, _}, &1)),
             """
             My own project's rows were not settled, so the scoping predicate is
             excluding the rows it is supposed to answer.

             #{inspect(verdicts(mine, "bdd_specs_exist"))}
             """
    end
  end

  # Give this project rows in the rows to sweep. A sweep settles rows and
  # never creates them, so a project the projector has never run for is
  # untouched for a reason that has nothing to do with scoping.
  defp project(%Scope{} = scope) do
    CodeMySpec.Requirements.recompute(scope)
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  # The vantage every project shares, and the only one where the bug is visible.
  defp unscoped(%Scope{} = scope), do: %Scope{scope | active_working_copy_id: nil}

  defp other_project_scope(%{scope: %Scope{} = scope}) do
    project = ProjectsFixtures.project_fixture(scope, %{name: "the other project"})
    unscoped(%{scope | active_project_id: project.id, active_project: project})
  end

  # Verdict and details per story, sorted — the whole answer, because a row
  # rewritten with the same verdict and a different reason is still a row
  # another project answered.
  defp verdicts(%Scope{active_project_id: project_id}, name) do
    from(n in "requirements",
      join: s in "stories",
      on: s.id == n.story_id,
      where: n.name == ^name and s.project_id == type(^project_id, :binary_id),
      where: is_nil(n.working_copy_id),
      select: {n.satisfied, n.details}
    )
    |> Repo.all()
    |> Enum.sort()
  end
end
