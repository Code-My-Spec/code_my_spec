defmodule CodeMySpecSpex.Story988.Criterion3484Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 3484 — An analyzer slower than the edit rate still answers for
  what it did read.

  Covers Rule "An analyzer's silence about a file is not a clean verdict."

  `Coverage`'s own moduledoc names the case a whole-corpus hash cannot serve:
  exunit takes ~2m20s here against an edit every couple of minutes, so
  `Fingerprint.current/2` is permanently behind and every result reads as
  stale project-wide (7a7eed33). Per-file coverage answers a narrower,
  always-current question instead — which files still hold what the
  analyzer saw — so a corpus that never stops moving still gets a real
  verdict on the part of it that held still.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Coverage narrows to the files that actually moved" do
    scenario "one covered file changes after the run, the other does not" do
      given_ "exunit has read two files", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/steady.ex",
            "defmodule MyApp.Steady do\nend\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/moving.ex",
            "defmodule MyApp.Moving do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        run = Fixtures.start_analysis_run(context.scope, "exunit")
        :ok = Fixtures.complete_analysis_run(context.scope, run)

        {:ok, context}
      end

      when_ "only one of the two files changes after the run finished", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/moving.ex",
            "defmodule MyApp.Moving do\n  # the corpus kept moving\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, context}
      end

      then_ "the unchanged file still answers current, only the moved one is stale", context do
        stale_paths =
          context.scope
          |> Fixtures.stale_coverage("exunit")
          |> Enum.map(& &1.path)

        assert "lib/my_app/moving.ex" in stale_paths,
               "the file that changed since the run must be named stale"

        refute "lib/my_app/steady.ex" in stale_paths,
               """
               An analyzer slower than the edit rate must not have its whole
               result invalidated by one file moving elsewhere in the corpus
               — that is the project-wide fingerprint's failure mode, and the
               one per-file coverage exists to avoid.
               """

        {:ok, context}
      end
    end
  end
end
