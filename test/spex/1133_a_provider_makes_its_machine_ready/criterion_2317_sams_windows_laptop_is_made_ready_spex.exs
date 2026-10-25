defmodule CodeMySpecSpex.Story1133.Criterion2317Spex do
  @moduledoc """
  Story 1133 — A provider makes its machine ready.
  Criterion 2317 — Sam's Windows laptop is made ready.

  Product's decision on this (the question this answers): the platform
  (os/arch) is an input the edge detects once and passes into
  `CmsHarness.Setup`, not something a spec has to literally run on — OS
  branching in `Prerequisites`/`Setup` is this story's own work, not a gap
  in the criterion. `DesktopSetupHelpers.as_platform/3` is the test-only
  seam for that input (see its doc); a real run on Windows is checked live
  later, the same way the live-QA rule covers what spex cannot.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine

  defp fresh_machine(context) do
    {:ok, context} = DesktopSetupHelpers.fresh_machine(context)
    context = DesktopSetupHelpers.as_platform(context, :windows, :x86_64)
    {:ok, DesktopSetupHelpers.with_fake_installer(context, "winget")}
  end

  spex "A Windows laptop is set up through mise and Windows installers", criterion: 2317 do
    scenario "Sam adds a Local box on a Windows laptop" do
      given_ "Sam adds a Local box on a Windows laptop", context do
        # given: already true — setup :fresh_machine creates this isolated machine.
        {:ok, context}
      end

      when_ "setup runs", context do
        {:ok, snapshot} =
          CodeMySpecSpex.Fixtures.check_platform_machine_prerequisites()

        {:ok, Map.put(context, :snapshot, snapshot)}
      end

      then_ "the toolchain comes from mise", context do
        commands = read_machine_file!(context, context.command_log)

        assert commands =~ ~r/^mise /m,
               "expected the toolchain step to run through mise on a Windows box:\n\n#{commands}"

        {:ok, context}
      end

      then_ "Erlang and Postgres come from their Windows installers", context do
        commands = read_machine_file!(context, context.command_log)

        assert commands =~ ~r/(choco|winget|msiexec|\.msi|installer)/i,
               "expected Erlang and Postgres to be installed through a Windows installer, " <>
                 "not checked as if this were Unix:\n\n#{commands}"

        {:ok, context}
      end

      then_ "the box is ready", context do
        assert CodeMySpecSpex.Fixtures.machine_prerequisites_passed?(context.snapshot)
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = CodeMySpec.ExecutionContexts.read_file(context.machine_environment, path)
    contents
  end
end
