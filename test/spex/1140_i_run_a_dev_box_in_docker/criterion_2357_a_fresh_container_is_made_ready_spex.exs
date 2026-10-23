defmodule CodeMySpecSpex.Story1140.Criterion2357Spex do
  @moduledoc """
  Story 1140 — I run a dev box in Docker.
  Criterion 2357 — A fresh container is made ready.

  A fresh Ubuntu container is a clean machine, so it is driven the way 1133
  drives any clean machine: the same prerequisite steps, whose outcomes are
  recorded in the setup results file (`CmsHarness.Setup`).
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "A new Docker box runs the same setup as any box", criterion: 2357 do
    scenario "The container starts from the clean image" do
      given_ "a new Docker box starts from the clean image", context do
        {:ok, context}
      end

      when_ "its setup runs", context do
        {:ok, snapshot} = CmsHarness.Setup.check_prerequisites()
        {:ok, Map.put(context, :snapshot, snapshot)}
      end

      then_ "the same setup steps run, each outcome recorded", context do
        assert Enum.any?(context.snapshot["steps"], &(&1["key"] == "postgres"))
        path = context.snapshot["results_path"]

        assert {:ok, _results} = Environments.read_file(context.machine_environment, path)
        {:ok, context}
      end

      then_ "the machine prerequisites are ready for project generation", context do
        assert CmsHarness.Setup.prerequisites_passed?(context.snapshot)
        {:ok, context}
      end
    end
  end
end
