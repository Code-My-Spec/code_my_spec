defmodule CodeMySpecSpex.Story1013.Criterion2357Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2357 — Not-onboarded is reported as itself.

  Rule: A working copy that was never onboarded says so before anything downstream
  fails.

  The rule the rest of the story is really about. Every incident behind story 1013
  had the same shape: a missing thing produced no error where it was missing, and
  surfaced far away wearing someone else's costume. A stale analyzer database
  arrived as `undefined_column` from inside a `given_` step. A submodule with no
  branch accepted every write and lost them silently. An unrecomputed requirement
  graph rendered as `0/0 satisfied`, which is also what a story requiring nothing
  looks like.

  In each case the actor had no way to distinguish *absent* from *fine*, and every
  one of them cost hours to a diagnosis that was one sentence long.

  So a working copy has to be able to answer the question directly rather than
  have it inferred from a downstream failure. `--check` is that question, and the
  second `then_` is what stops the answer being a bare boolean an agent still has
  to interpret.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Absence reports itself" do
    scenario "Not-onboarded is reported as itself" do
      given_ "a working copy that was never onboarded", context do
        :ok = Environments.register(context.project.id, context.environment)
        {:ok, context}
      end

      when_ "something asks whether it is onboarded", context do
        Mix.Task.reenable("cms.harness.onboard")

        status =
          Mix.Task.run("cms.harness.onboard", [
            "--project",
            context.project.id,
            "--check"
          ])

        {:ok, Map.put(context, :status, status)}
      end

      then_ "it is told the working copy is not onboarded", context do
        assert %{onboarded: false} = context.status,
               "asking an un-onboarded working copy whether it is onboarded did not " <>
                 "produce that answer. An agent then learns it from whatever fails " <>
                 "next — a bulk suite failure, a missing column, a refused stop — " <>
                 "none of which name the cause. Got: #{inspect(context.status)}"

        {:ok, context}
      end

      then_ "it is told what to run", context do
        assert %{remedy: remedy} = context.status

        assert is_binary(remedy) and String.contains?(remedy, "mix"),
               "the working copy reported that it is not onboarded without saying " <>
                 "what would onboard it. Naming a state and withholding its remedy is " <>
                 "the migration guard's failure exactly: it refused correctly, and " <>
                 "the command it printed could not fix the thing it had refused over. " <>
                 "Got: #{inspect(context.status)}"

        {:ok, context}
      end
    end
  end
end
