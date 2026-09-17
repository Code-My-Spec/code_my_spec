defmodule CodeMySpecSpex.Story988.Criterion3483Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 3483 — A file edited while the run was in flight is not
  recorded as read.

  Covers Rule "An analyzer's silence about a file is not a clean verdict."

  `Coverage.seen_entries/3` draws the line at the run's own `started_at`: a
  file touched after the run began is left out, deliberately, rather than
  recorded at the content it now holds. The unit-level proof of this is
  `ARunRecordsWhatItReadTest`; this is the same claim driven the way a spex
  drives everything else here — write the file, let the harness observe it —
  rather than through `Files.upsert_files/2` directly, which no agent-facing
  path calls.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A run's read boundary is when it started, not when it finished" do
    scenario "one file is edited after the run begins, another is left alone" do
      given_ "two files exist before exunit starts", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/untouched.ex",
            "defmodule MyApp.Untouched do\nend\n"
          )

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/edited.ex",
            "defmodule MyApp.Edited do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, context}
      end

      when_ "the run starts, and one file is edited before it finishes", context do
        run = Fixtures.start_analysis_run(context.scope, "exunit")

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/edited.ex",
            "defmodule MyApp.Edited do\n  # landed while exunit was running\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        :ok = Fixtures.complete_analysis_run(context.scope, run)

        {:ok, context}
      end

      then_ "the edited file is unread and the untouched one is not", context do
        unread =
          context.scope
          |> Fixtures.unread_files("exunit")
          |> Enum.map(& &1.path)

        assert "lib/my_app/edited.ex" in unread,
               """
               The analyzer read the bytes present when it started, not the
               ones the file holds now. Recording it as read at content it
               never saw is a false fact, permanently — worse than staying
               unread, which at least says so honestly.
               """

        refute "lib/my_app/untouched.ex" in unread,
               "a file the run genuinely covered, unchanged since, must not be reported as unread"

        {:ok, context}
      end
    end
  end
end
