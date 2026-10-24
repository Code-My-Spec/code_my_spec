defmodule CodeMySpecSpex.Story1133.Criterion2318Spex do
  @moduledoc """
  Story 1133 — A provider makes its machine ready.
  Criterion 2318 — Sam's ARM Mac is made ready.

  Same basis as criterion 2317: platform is an input `DesktopSetupHelpers.as_platform/3`
  injects for the spec, not something it has to literally run on.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine

  defp fresh_machine(context) do
    {:ok, context} = DesktopSetupHelpers.fresh_machine(context)
    context = DesktopSetupHelpers.as_platform(context, :darwin, :aarch64)
    {:ok, DesktopSetupHelpers.with_fake_installer(context, "arch")}
  end

  spex "Every prerequisite on an ARM Mac is installed for ARM", criterion: 2318 do
    scenario "Sam adds a Local box on an Apple Silicon Mac" do
      given_ "Sam adds a Local box on an Apple Silicon Mac", context do
        # given: already true — setup :fresh_machine creates this isolated machine.
        {:ok, context}
      end

      when_ "setup runs", context do
        {:ok, snapshot} =
          CmsHarness.Setup.check_prerequisites(platform: CmsHarness.Setup.Platform.detect())

        {:ok, Map.put(context, :snapshot, snapshot)}
      end

      then_ "every prerequisite is installed for ARM", context do
        commands = read_machine_file!(context, context.command_log)

        assert commands =~ ~r/(arm64|aarch64)/i,
               "expected prerequisite steps to name the arm64/aarch64 artifact on an " <>
                 "Apple Silicon box:\n\n#{commands}"

        {:ok, context}
      end

      then_ "the box is ready", context do
        assert CmsHarness.Setup.prerequisites_passed?(context.snapshot)
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = CodeMySpec.Environments.read_file(context.machine_environment, path)
    contents
  end
end
