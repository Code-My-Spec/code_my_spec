defmodule CodeMySpec.Requirements.AFileInOneCheckoutIsMissingFromAnotherTest do
  @moduledoc """
  A file that only one checkout has must read as missing from the others.

  Issue `78d08d86`, second attempt. The first drove a *removal* — a file present
  and then deleted — and settled correctly, which ruled the hypothesis out
  without explaining the symptom.

  This drives the starting state the symptom actually had. On dev, 25 components
  on `963-main-agent-nontechnical` reported "implementation file exists" for
  files that exist on main and not on that branch. That checkout never had them;
  nothing was removed from it. Over-satisfaction is the expensive direction —
  an agent is told the work is done and skips it, which `Preloader`'s moduledoc
  measured at 303 components.

  ## This passes, and that is the second negative result on this issue

  It was written to reproduce the dev symptom and does not. Once both checkouts
  are actually projected, the checkout without the file reports it missing, as
  it should. The first attempt drove a *removal* and also settled correctly.

  So the event path is right in both isolated cases, and whatever happened on
  dev is not a logic error in either of them. What is left is timing: dev had
  ten checkouts under continuous concurrent work, and the symptom appeared and
  cleared over about ten minutes. That is the shape of a read taken while
  another vantage was mid-settle, not of a wrong rule.

  ## The step that made the difference, worth knowing

  A vantage enters `Projection.vantages/1` only once something has computed for
  it. Before `recompute/1` below, the second checkout had **no rows at all** and
  the verdict read `nil` — which an assertion of `== false` reports as "still
  present", and which cost an hour of chasing a reproduction that was really an
  unprojected checkout.

  ## Why a unit test rather than a spex

  It exercises the incremental graph directly, and the rows are development
  scaffolding — no rule or criterion on story 1020 asserts on it, deliberately.
  Testing the scaffolding is worth doing; claiming it in the story is not.
  """
  use CodeMySpecSpex.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias CodeMySpec.Environments
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Requirements.{IncrementalGraph, Projection}
  alias CodeMySpecSpex.Fixtures

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

  # What the event path says about this component's implementation file at this
  # checkout. Read from the graph rows because the endpoint serves the pass's
  # answer, and the pass is not what is under test.
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

  defp scoped_to_copy(nil, query), do: from(n in query, where: is_nil(n.working_copy_id))

  defp scoped_to_copy(copy, query),
    do: from(n in query, where: n.working_copy_id == type(^copy, :binary_id))

  describe "a file only one checkout has" do
    test "is missing from the checkout that never had it", ctx do
      first = ctx.scope

      component =
        CodeMySpec.ComponentsFixtures.component_fixture(first, %{
          name: "ExampleContext",
          module_name: "ExampleContext",
          type: "context"
        })

      # Its own root and its own environment, the way a second worktree is.
      second = Fixtures.live_agent_scope(first, label: "the checkout without it")

      refute second.active_working_copy_id == first.active_working_copy_id,
             "two checkouts must be two copies; the fixture issued one id for both"

      # The file exists in the first checkout only. The second one's tree is
      # real and empty — the state a branch that never carried the file is in.
      :ok =
        Environments.write_file(
          ctx.environment,
          @impl_path,
          "defmodule ExampleContext do\nend\n"
        )

      {:ok, _} = FileSync.sync(first)
      {:ok, _} = FileSync.sync(second)

      # A vantage enters `Projection.vantages/1` only once something has computed
      # for it, so the second checkout has to be projected before it can be
      # wrong about anything. This is what a reader arriving at that checkout
      # does.
      CodeMySpec.Requirements.recompute(second)
      settle(second)
      settle(first)

      IO.puts(
        "ACTUAL first=#{inspect(served_verdict(first, component.id))} " <>
          "second=#{inspect(served_verdict(second, component.id))}"
      )

      assert served_verdict(first, component.id) == true,
             "the checkout holding the file does not report it present"

      assert served_verdict(second, component.id) == false,
             """
             A checkout that has never held this file reports it present.

             The file is in the other worktree and in no tree this checkout can
             see. Reading it as present here is the blended read `Preloader`
             measured at 303 components — an agent told the work is done, in a
             tree where nobody has done it.
             """
    end
  end
end
