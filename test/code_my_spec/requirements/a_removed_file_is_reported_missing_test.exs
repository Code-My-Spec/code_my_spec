defmodule CodeMySpec.Requirements.ARemovedFileIsReportedMissingTest do
  @moduledoc """
  A file going away has to move the verdict that said it was there.

  Issue `78d08d86`. Observed on dev, 2026-09-17: the event path reported
  "implementation file exists" for 25 components whose file had no row for that
  checkout and was not on disk in that worktree — files that exist on main and
  not on that branch. The pass said "missing" and was right. Over-satisfaction
  is the expensive direction: an agent is told the work is done and skips it,
  which `Preloader`'s moduledoc measured at 303 components.

  It cleared about ten minutes later when some unrelated observation named that
  checkout, so the window is bounded by nothing in particular. Today that only
  corrupts a table nobody reads; after `graph_event_is_source` flips it is what
  agents are told.

  ## Why a unit test rather than a spex

  This exercises the incremental graph directly, and the rows are development
  scaffolding — no rule or criterion on story 1020 asserts on it, deliberately.
  Testing the scaffolding is still worth doing; claiming it in the story is not.

  ## This passes today, and that is the finding

  It was written to reproduce the dev symptom and does not. A removal driven
  through the environment and a real sync settles correctly, with or without the
  change that was going to be the fix — keeping the `:unknown` fallback alive
  past `split_handled/2` made no difference here, so whatever went wrong on dev
  is not this shape.

  Kept anyway. The claim is real and worth guarding: a file that was there and
  is gone has to stop being reported present, and over-satisfaction is the
  expensive direction — an agent is told the work is done and skips it, which
  `Preloader`'s moduledoc measured at 303 components.

  What is still unexplained is in issue `78d08d86`: 25 components on one
  checkout reporting an implementation file that had no row there and was not on
  disk, cleared about ten minutes later by an unrelated observation. The next
  thing to vary is the *two-checkout* case — the dev symptom was on a worktree
  whose branch lacked files that main had, and this test has only one.
  """
  use CodeMySpecSpex.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.{IncrementalGraph, Projection}

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    :ok
  end

  @impl_path "lib/example_context.ex"

  defp settle(scope) do
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
  end

  # What the event path says about this component's implementation file, at this
  # checkout. Read from the graph rows rather than the endpoint because the
  # endpoint serves the pass's answer, and the pass is not what is under test.
  defp served_verdict(scope, component_id) do
    base =
      from(n in "requirements",
        where:
          n.component_id == type(^component_id, :binary_id) and
            n.name == "implementation_file",
        select: type(n.satisfied, :boolean)
      )

    scope
    |> Projection.vantage()
    |> scoped_to_copy(base)
    |> CodeMySpec.Repo.one()
  end

  defp scoped_to_copy(nil, query),
    do: from(n in query, where: is_nil(n.working_copy_id))

  defp scoped_to_copy(copy, query),
    do: from(n in query, where: n.working_copy_id == type(^copy, :binary_id))

  describe "a file that was there and is not any more" do
    test "stops being reported as present", %{scope: scope, execution_context: env} do
      component =
        CodeMySpec.ComponentsFixtures.component_fixture(scope, %{
          name: "ExampleContext",
          module_name: "ExampleContext",
          type: "context"
        })

      # Through the environment and a real sync, which is the path that
      # announces. `Files.delete_removed/2` alone writes no mark, so a test
      # built on it measures a projector with nothing to drain.
      :ok = ExecutionContexts.write_file(env, @impl_path, "defmodule ExampleContext do\nend\n")
      {:ok, _} = FileSync.sync(scope)
      settle(scope)

      assert served_verdict(scope, component.id) == true,
             "the file was synced and the event path does not report it present"

      :ok = ExecutionContexts.delete_file(env, @impl_path)
      {:ok, _} = FileSync.sync(scope)
      settle(scope)

      assert served_verdict(scope, component.id) == false,
             """
             The file is gone and the event path still reports it present.

             Over-satisfaction is the expensive direction: an agent reading this
             is told the implementation exists and skips writing it. The removal
             named no entities, so the event was recorded `:unknown` — and its
             fallback has to survive, because a handler cannot have settled
             everything an event moved when nothing knows what that was.
             """
    end
  end
end
