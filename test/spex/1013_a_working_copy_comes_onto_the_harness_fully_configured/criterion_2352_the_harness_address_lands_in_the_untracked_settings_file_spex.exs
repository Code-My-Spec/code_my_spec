defmodule CodeMySpecSpex.Story1013.Criterion2352Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2352 — The harness address lands in the untracked settings file.

  Rule: Values that identify this machine are written only to files git does not
  track.

  The Anthropic base URL carries this working copy's harness id. `settings.json`
  is tracked, so writing it there stages one machine's identity for commit and
  the next clone inherits it — the same corruption the id exists to prevent, and
  the reason the plugin is generated per copy rather than edited in place.

  Not hypothetical. It was written to the tracked file and corrected the same day
  (ff18c21f). A spec is what stops it happening a third time.

  The second `then_` is the one with teeth. Writing the right file is easy to get
  right by accident; leaving the tracked file *alone* is what a well-meaning
  "make sure the setting is present everywhere" change would quietly break.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @tracked ".claude/settings.json"
  @untracked ".claude/settings.local.json"

  spex "Machine identity stays out of files git tracks" do
    scenario "The harness address lands in the untracked settings file" do
      given_ "a working copy whose tracked settings file already has content", context do
        :ok = Environments.register(context.project.id, context.environment)
        System.put_env("CMS_PROJECT_ID", context.project.id)
        on_exit(fn -> System.delete_env("CMS_PROJECT_ID") end)

        tracked = ~s({\n  "permissions": {\n    "allow": []\n  }\n}\n)
        :ok = Environments.write_file(context.environment, @tracked, tracked)

        {:ok, Map.put(context, :tracked_before, tracked)}
      end

      when_ "the engineer runs the onboarding task in it", context do
        # By name, not by module. `CodeMySpecSpex` may reference only
        # `Environments`, `McpServers`, `Fixtures` and the two web boundaries — so
        # calling the task directly is a boundary violation. Running it the way an
        # engineer does is both legal and the more faithful surface.
        Mix.Task.reenable("cms.onboard_harness")
        Mix.Task.run("cms.onboard_harness", [])

        {:ok, context}
      end

      then_ "the address is in the untracked settings file", context do
        assert {:ok, contents} = Environments.read_file(context.environment, @untracked),
               "onboarding wrote no #{@untracked}. The Anthropic base URL carries " <>
                 "this working copy's harness id, and the untracked file is the only " <>
                 "place it can go without being staged for commit."

        assert contents =~ "ANTHROPIC_BASE_URL",
               "#{@untracked} exists but carries no Anthropic base URL, so agent " <>
                 "traffic does not relay through the harness and nothing reaches the " <>
                 "server. Got: #{contents}"

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
