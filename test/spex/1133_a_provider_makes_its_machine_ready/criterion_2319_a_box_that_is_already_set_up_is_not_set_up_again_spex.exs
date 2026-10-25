defmodule CodeMySpecSpex.Story1133.Criterion2319Spex do
  @moduledoc """
  Story 1133 — A provider makes its machine ready.
  Criterion 2319 — A box that is already set up is not set up again.

  `CmsHarness.Setup` retains a run's results file and only starts another on
  explicit action (its own moduledoc). The desktop app's boot reads that
  file the same way reopening it does in story 1112 — there is no separate
  "harness starts" surface from "the app opens" for a Local box, so this
  drives the same `/app` mount and reads the same recorded files.
  """
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "A box with yesterday's setup on record is not set up again today", criterion: 2319 do
    scenario "The harness starts a day after setup finished" do
      given_ "Sam's box finished setup yesterday", context do
        {:ok, _snapshot} = CodeMySpecSpex.Fixtures.check_machine_prerequisites()

        {:ok,
         Map.merge(context, %{
           recorded_commands: read_machine_file!(context, context.command_log)
         })}
      end

      when_ "its harness starts today", context do
        {:ok, reopened, _} = live(context.conn, "/app")
        render_async(reopened, 10_000)
        {:ok, Map.put(context, :reopened, reopened)}
      end

      then_ "setup does not run again", context do
        assert read_machine_file!(context, context.command_log) == context.recorded_commands,
               "reopening ran prerequisite checks again instead of reading yesterday's record"

        {:ok, context}
      end

      then_ "the record of yesterday's setup is still readable", context do
        assert {:ok, snapshot} = CodeMySpecSpex.Fixtures.machine_setup_status()
        path = snapshot["results_path"]

        assert {:ok, _results} = ExecutionContexts.read_file(context.machine_environment, path)
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = ExecutionContexts.read_file(context.machine_environment, path)
    contents
  end
end
