defmodule CodeMySpecSpex.Story1013.Criterion2361Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2361 — Submodules follow the working copy without being asked.

  Rule: Onboarding configures the working copy to recurse submodules.

  `.code_my_spec` is a submodule, and a submodule sits in detached HEAD by design
  — `git submodule update` checks out a recorded SHA, not a branch. So it accepts
  writes normally and has no branch to carry them.

  The consequence was measured on 2026-08-13: four QA briefs, including the
  evidence behind a story shipped with QA recorded complete, existed in exactly
  one working copy and nowhere else. Nothing reported a problem, because the one
  signal that would have — the superproject's dirty-pointer line — is suppressed
  project-wide by `--ignore-submodules=all`, for well-reasoned unrelated purposes.

  Recursing by default does not fix the commit half, and this criterion does not
  claim it does. It fixes the half where a pull moves the pointer and the
  submodule silently stays behind, which is how a checkout ends up holding content
  from a commit nobody is working on.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Submodules follow the working copy" do
    scenario "Submodules follow the working copy without being asked" do
      given_ "a working copy whose git config does not recurse submodules", context do
        :ok = Environments.register(context.project.id, context.environment)
        {:ok, context}
      end

      when_ "the engineer runs the onboarding task in it", context do
        Mix.Task.reenable("cms.onboard_harness")
        report = Mix.Task.run("cms.onboard_harness", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "git recurses submodules for this working copy", context do
        assert %{git: %{submodule_recurse: true}} = context.report,
               "onboarding left submodule recursion off. A pull that moves a " <>
                 "submodule pointer then leaves the submodule behind, and the " <>
                 "superproject's warning about it is suppressed project-wide — so the " <>
                 "checkout holds content from a commit nobody is working on and " <>
                 "nothing says so. Got: #{inspect(context.report)}"

        {:ok, context}
      end
    end
  end
end
