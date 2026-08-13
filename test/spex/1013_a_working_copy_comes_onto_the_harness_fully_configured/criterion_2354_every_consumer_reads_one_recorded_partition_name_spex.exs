defmodule CodeMySpecSpex.Story1013.Criterion2354Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2354 — Every consumer reads one recorded partition name.

  Rule: The test partition is assigned once at onboarding and read from
  configuration thereafter, never derived.

  Today there are two derivations of one identity. `config/test.exs` builds a name
  from the worktree path when `MIX_TEST_PARTITION` is unset; `TestDatabase`
  digests the cwd to `h<sha8>` and appends `s` for spex. `analyzer_env.ex` says
  what follows in its own words: "different databases, by accident of two
  mechanisms rather than by design".

  Assigned-and-recorded is what removes the class. Two derivations can disagree;
  two readers of one recorded value cannot.

  The second `then_` is the load-bearing one. A single recorded name that nothing
  reads is the same failure wearing better clothes — so the recorded value has to
  be the one that reaches the environment consumers actually see.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @settings ".claude/settings.local.json"

  spex "One partition name, recorded and read" do
    scenario "Every consumer reads one recorded partition name" do
      given_ "a working copy with no partition recorded", context do
        :ok = Environments.register(context.project.id, context.environment)
        {:ok, context}
      end

      when_ "the engineer runs the onboarding task", context do
        Mix.Task.reenable("cms.onboard_harness")
        report = Mix.Task.run("cms.onboard_harness", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "exactly one partition name is assigned", context do
        assert %{partition: partition} = context.report

        assert is_binary(partition) and partition != "",
               "onboarding recorded no partition name, so every consumer falls back " <>
                 "to deriving one and the two derivations resume disagreeing. Got: " <>
                 inspect(context.report)

        {:ok, context}
      end

      then_ "that same name is what the working copy's configuration carries", context do
        assert {:ok, settings} = Environments.read_file(context.environment, @settings)

        assert settings =~ context.report.partition,
               "the recorded partition and the one in #{@settings} are different " <>
                 "values. A name assigned but not published is the two-mechanism " <>
                 "problem again with an extra step: consumers read the file, so the " <>
                 "file is the recording. Expected #{context.report.partition} in: " <>
                 settings

        {:ok, context}
      end
    end
  end
end
