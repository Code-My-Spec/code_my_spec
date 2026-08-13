defmodule CodeMySpecSpex.Story1013.Criterion2351Spex do
  @moduledoc """
  Story 1013 — A working copy comes onto the harness fully configured.
  Criterion 2351 — A generated application onboards itself with the same command.

  Rule: Onboarding ships where a target application can run it, not only where
  CodeMySpec can.

  The placement decision, asserted rather than asserted-about. The portable work
  lives in `client_utils` because a generated application depends on that and not
  on CodeMySpec — so it is the only placement where both can onboard themselves.
  `client_utils` is already a dependency here (`mix.exs`), which is why moving it
  there costs this repo nothing.

  It also inverts the dependency correctly: `client_utils` writes the partition
  name and CodeMySpec reads it, so `client_utils` never learns a digest algorithm
  that should no longer exist.

  Encoded as *the same command produces the same configuration on a working copy
  with nothing CodeMySpec-specific about it*. A version of this that only worked
  where CodeMySpec's own modules are loaded would pass a weaker reading of every
  other criterion in this story while leaving generated applications exactly where
  they are now: onboarded by hand, or not at all.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  @settings ".claude/settings.local.json"

  spex "Onboarding is portable to any application that depends on client_utils" do
    scenario "A generated application onboards itself with the same command" do
      given_ "a working copy with nothing CodeMySpec-specific in it", context do
        :ok = Environments.register(context.project.id, context.environment)

        refute Environments.file_exists?(context.environment, ".code_my_spec/config.yml"),
               "the premise failed: this working copy carries CodeMySpec's own " <>
                 "configuration, so onboarding it proves nothing about a generated app"

        {:ok, context}
      end

      when_ "the same onboarding command runs in it", context do
        Mix.Task.reenable("cms.harness.onboard")
        report = Mix.Task.run("cms.harness.onboard", ["--project", context.project.id])

        {:ok, Map.put(context, :report, report)}
      end

      then_ "it is configured the same way CodeMySpec's own copies are", context do
        assert {:ok, settings} = Environments.read_file(context.environment, @settings),
               "onboarding produced no configuration for a working copy that is not " <>
                 "CodeMySpec's own. A generated application is then left to be " <>
                 "onboarded by hand, which is the state this story exists to end."

        assert settings =~ "ANTHROPIC_BASE_URL" and settings =~ "MIX_TEST_PARTITION",
               "a generated application got a partial configuration. Same command, " <>
                 "same result is the whole claim — a second, lesser onboarding path " <>
                 "for target apps is two mechanisms again. Got: #{settings}"

        {:ok, context}
      end

      then_ "it is told the same outstanding work", context do
        assert %{databases: [_ | _]} = context.report,
               "no outstanding databases were reported for a generated application, " <>
                 "though it needs them exactly as this repo does. Got: " <>
                 inspect(context.report)

        {:ok, context}
      end
    end
  end
end
