defmodule CodeMySpec.AgentTasks.ArchitectureDesignUnobservableTest do
  @moduledoc """
  A checker that could not look must not answer as though it looked.

  `074b7c83`: starting `architecture_designed` on a light harness made every
  subsequent stop unpassable. The gate's entire answer was

      [StopHook] [c8a41846] Blocking: Error: :no_environment

  with no task named, no working copy, and nothing to act on. `cancel_task` was
  the only escape, and nothing in the message pointed at it.

  `TaskEvaluator` already had the branch for this — `f7dc9c47` built it, and it
  says "not a requirement failure … do not rewrite the work". It was never
  reached, because `evaluate_initial_mode/3` ended in a catch-all that turned
  every `{:error, reason}` into `{:ok, :invalid, "Error: …"}`. A verdict, and
  `TaskEvaluator` records verdicts as feedback. The one message built for this
  case was unreachable from the one path that produced it.

  Two things are pinned here, because fixing either alone leaves the bug:
  the evaluator has to *emit* an unobservable error, and it has to keep
  emitting verdicts for everything else.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.ArchitectureDesign
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  describe "an environment that cannot answer" do
    test "is reported as unobservable, not as an unmet requirement" do
      scope = %{full_scope_fixture() | environment: nil}

      assert ArchitectureDesign.evaluate(scope, %{id: 1}) == {:error, :no_environment},
             "flattened to `{:ok, :invalid, _}` this becomes the gate's verdict, and the " <>
               "TaskEvaluator branch that explains it is never reached"
    end

    # The mode is chosen by `file_exists?/2` on a marker file, and that answers
    # `false` for "no disk" exactly as it does for "not there" — the asymmetry
    # `Environments`' own moduledoc warns about. So a nil environment did not
    # fail to pick a mode, it picked `initial`, whose evaluator "validates the
    # proposal AND executes it as one transaction — creating spec files and
    # linking stories". On a project with 903 components that is a mass rewrite.
    test "does not fall through to the mode that rewrites the proposal" do
      scope = %{full_scope_fixture() | environment: nil}

      refute match?({:ok, :invalid, _}, ArchitectureDesign.evaluate(scope, %{id: 1}))
      refute match?({:ok, :valid}, ArchitectureDesign.evaluate(scope, %{id: 1}))
    end
  end

  describe "an environment that can answer" do
    setup do
      {:ok, tmp} = Briefly.create(directory: true)
      %{scope: %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}}
    end

    # The other half. "Could not look" and "looked, and it is not there" are
    # different answers, and only the first is a framework bug — a missing
    # proposal is genuinely the agent's to fix, so it must stay a verdict.
    test "a missing proposal is still a requirement failure", ctx do
      assert {:ok, :invalid, feedback} = ArchitectureDesign.evaluate(ctx.scope, %{id: 1})
      assert is_binary(feedback)
    end
  end

  describe "the shared predicate" do
    # `TaskEvaluator` and the evaluator both branch on this. Two copies of the
    # list would drift, and the drift is silent: the explaining branch simply
    # stops being reached, which is the bug this test file is about.
    test "recognises the error every file operation returns without a disk" do
      assert Environments.unobservable?(:no_environment)
      assert Environments.unobservable?({:error, :no_environment})
      refute Environments.unobservable?(:enoent)
      refute Environments.unobservable?({:error, :enoent})
    end
  end
end
