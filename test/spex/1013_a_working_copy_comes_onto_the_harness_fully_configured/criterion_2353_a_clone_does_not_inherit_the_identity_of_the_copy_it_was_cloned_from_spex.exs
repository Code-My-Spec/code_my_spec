defmodule CodeMySpecSpex.Story1013.Criterion2353Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2353 — A clone does not inherit the identity of the copy it was cloned
  from.

  Rule: Values that identify this machine are written only to files git does not
  track.

  The consequence criterion 2352 exists to prevent, asserted from the other end. A
  harness id in a tracked file travels: the next clone starts life believing it
  has been onboarded, talks to a harness that belongs to another machine, and
  every problem and file it reports is attributed to a working copy it is not.

  That is worse than an unconfigured clone, which at least fails in a way that
  names itself. This one works — incorrectly and quietly — which is why the id is
  generated per copy rather than committed.

  Asserted as the absence of the identity from tracked files rather than by
  performing a clone, because the tracked set is what a clone receives, and it is
  a thing a spec can read.

  ## Why it reads the untracked file first (issue `214d8050`)

  Both assertions here are refutes against the contents of `.claude/settings.json`,
  and the `given_` seeds that file with `{}`. So an onboarding run that did
  nothing at all — a task that errored, a project id it would not accept — leaves
  `{}` behind, and `{}` contains neither the harness id nor `ANTHROPIC_BASE_URL`.
  The criterion passed hardest in exactly the case where nothing was configured.

  The rule is "written only to files git does not track", and *only* is a contrast
  between two files. Reading the untracked one first makes it one: the values are
  here, and therefore demonstrably not merely absent everywhere.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @tracked ".claude/settings.json"
  @untracked ".claude/settings.local.json"

  spex "Identity does not travel with the repository" do
    scenario "A clone does not inherit the identity of the copy it was cloned from" do
      given_ "a working copy onboarded on this machine", context do
        :ok = Environments.register(context.project.id, context.environment)

        :ok =
          Environments.write_file(
            context.environment,
            ".cms_harness.json",
            Jason.encode!(%{harness_id: "spex-harness-2353"}, pretty: true)
          )

        :ok = Environments.write_file(context.environment, @tracked, "{}\n")

        Mix.Task.reenable("cms.harness.onboard")
        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      when_ "the tracked files that a clone would receive are read", context do
        {:ok, tracked} = Environments.read_file(context.environment, @tracked)
        {:ok, untracked} = Environments.read_file(context.environment, @untracked)

        {:ok, context |> Map.put(:tracked, tracked) |> Map.put(:untracked, untracked)}
      end

      then_ "this machine's identity was written somewhere", context do
        assert context.untracked =~ context.report.harness_id,
               "onboarding wrote this machine's harness id into neither file. The " <>
                 "refutes below would then hold because nothing was configured, " <>
                 "which is the one case this criterion is not about. Got " <>
                 "#{@untracked}: #{context.untracked}"

        {:ok, context}
      end

      then_ "this machine's harness id is nowhere in them", context do
        refute context.tracked =~ context.report.harness_id,
               "this working copy's harness id is in #{@tracked}, which git tracks. " <>
                 "The next clone would inherit it, report its files and problems " <>
                 "against another machine's harness, and give no sign of doing so — " <>
                 "it would look onboarded and be wrong. Got: #{context.tracked}"

        {:ok, context}
      end

      then_ "a clone would therefore carry no identity of its own", context do
        refute context.tracked =~ "ANTHROPIC_BASE_URL",
               "the Anthropic base URL is in a tracked file. It carries the harness " <>
                 "id in its host, so committing it hands the clone an address " <>
                 "pointing at the machine it was cloned from — the corruption the id " <>
                 "exists to prevent. Got: #{context.tracked}"

        {:ok, context}
      end
    end
  end
end
