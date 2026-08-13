defmodule CodeMySpecSpex.Story1013.Criterion2352Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2352 — The harness address lands in the untracked settings file.

  Rule: Values that identify this machine are written only to files git does not
  track.

  The Anthropic base URL carries this working copy's harness id. `settings.json`
  is tracked, so writing it there stages one machine's identity for commit and
  the next clone inherits it — the same corruption the id exists to prevent.

  Not hypothetical. It was written to the tracked file and corrected the same day
  (ff18c21f). A spec is what stops it happening a third time.

  The second `then_` is the one with teeth. Writing the right file is easy to get
  right by accident; leaving the tracked file *alone* is what a well-meaning
  "make sure the setting is present everywhere" change would quietly break.

  ## The surface is the filesystem

  Everything onboarding does that this criterion cares about is a file, so the
  in-memory environment sees all of it. An earlier version of this spec built a
  real directory — temp dir, git repo, plugin tree, hand-written harness config
  — which was four fixtures standing in for one surface, and it only existed
  because the task wrote with `File.write!/2`. The boundary said so before I did:
  `CodeMySpecSpex` may not reach into `CmsHarness`, and the answer to that is not
  to write its bytes yourself.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @tracked ".claude/settings.json"
  @untracked ".claude/settings.local.json"
  @harness_config ".cms_harness.json"

  spex "Machine identity stays out of files git tracks" do
    scenario "The harness address lands in the untracked settings file" do
      given_ "a working copy with an id, whose tracked settings already have content",
             context do
        :ok = Environments.register(context.project.id, context.environment)

        # An id already on the copy, written through the same surface the task
        # reads it from. This is the ordinary case — a copy being onboarded again
        # — and it is what keeps the spec off the network: the task mints only
        # when there is no id to find.
        :ok =
          Environments.write_file(
            context.environment,
            @harness_config,
            Jason.encode!(%{harness_id: "spex-harness-2352"}, pretty: true)
          )

        tracked = ~s({\n  "permissions": {\n    "allow": []\n  }\n}\n)
        :ok = Environments.write_file(context.environment, @tracked, tracked)

        {:ok, Map.put(context, :tracked_before, tracked)}
      end

      when_ "the engineer runs the onboarding task in it", context do
        Mix.Task.reenable("cms.harness.onboard")
        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "the address is in the untracked settings file", context do
        assert {:ok, contents} = Environments.read_file(context.environment, @untracked),
               "onboarding wrote no #{@untracked}. The Anthropic base URL carries " <>
                 "this working copy's harness id, and the untracked file is the only " <>
                 "place it can go without being staged for commit."

        assert contents =~ "ANTHROPIC_BASE_URL",
               "#{@untracked} carries no Anthropic base URL, so agent traffic does " <>
                 "not relay through the harness and no agent work reaches the " <>
                 "server. Got: #{contents}"

        assert contents =~ "spex-harness-2352",
               "the address does not carry this working copy's own id, so every turn " <>
                 "it relays is attributed to no checkout in particular. Got: #{contents}"

        {:ok, context}
      end

      then_ "the tracked settings file is byte-for-byte unchanged", context do
        assert {:ok, after_run} = Environments.read_file(context.environment, @tracked)

        assert after_run == context.tracked_before,
               "onboarding modified #{@tracked}, which git tracks. The URL carries " <>
                 "this machine's harness id, so committing it hands the next clone an " <>
                 "identity that is not its own — it would talk to another machine's " <>
                 "harness while believing it had been onboarded. This exact write " <>
                 "happened on 2026-08-13 and was reverted in ff18c21f."

        {:ok, context}
      end
    end
  end
end
