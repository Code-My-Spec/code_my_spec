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

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.DesktopSetupHelpers

  setup :fresh_machine
  defp fresh_machine(context), do: DesktopSetupHelpers.fresh_machine(context)

  spex "A box with yesterday's setup on record is not set up again today", criterion: 2319 do
    scenario "The harness starts a day after setup finished" do
      given_ "Sam's box finished setup yesterday", context do
        {:ok, view, _} = live(context.conn, "/app")
        view |> element("[data-test='check-prerequisites']") |> render_click()
        render_async(view, 10_000)

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
        assert has_element?(context.reopened, "[data-test='setup-results-file'][data-path]")

        [path] =
          context.reopened
          |> element("[data-test='setup-results-file']")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("data-path")

        assert {:ok, _results} = Environments.read_file(context.machine_environment, path)
        {:ok, context}
      end
    end
  end

  defp read_machine_file!(context, path) do
    {:ok, contents} = Environments.read_file(context.machine_environment, path)
    contents
  end
end
