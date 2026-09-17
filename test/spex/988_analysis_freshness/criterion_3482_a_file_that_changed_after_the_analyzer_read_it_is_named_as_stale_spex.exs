defmodule CodeMySpecSpex.Story988.Criterion3482Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 3482 — A file that changed after the analyzer read it is named
  as stale.

  Covers Rule "An analyzer's silence about a file is not a clean verdict."

  The other half of 3481. Reading a file and finding nothing is a real
  answer `Coverage.record/4` can give, and it has to keep meaning that after
  the file moves on — `stale_files/2` and `stale_report/2` exist so "why is
  this stale" has an answer scoped to the one file that changed, not the
  project-wide boolean this table replaces.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A file's coverage row is checked against what the file holds now" do
    scenario "exunit read the file, then the file changed" do
      given_ "exunit has read the file at its current content", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/drifted.ex",
            "defmodule MyApp.Drifted do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        run = Fixtures.start_analysis_run(context.scope, "exunit")
        :ok = Fixtures.complete_analysis_run(context.scope, run)

        refute Enum.any?(
                 Fixtures.unread_files(context.scope, "exunit"),
                 &(&1.path == "lib/my_app/drifted.ex")
               ),
               "the premise is that exunit already read this file — it must not start out unread"

        {:ok, context}
      end

      when_ "the file changes after the run finished", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/drifted.ex",
            "defmodule MyApp.Drifted do\n  # edited after the run\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, context}
      end

      then_ "the file is named as stale, not folded back into unread or clean", context do
        stale = Fixtures.stale_coverage(context.scope, "exunit")
        entry = Enum.find(stale, &(&1.path == "lib/my_app/drifted.ex"))

        assert entry,
               """
               A file that moved since it was read must be named — the whole
               reason per-file coverage exists is to answer "why is this
               stale" instead of only "something changed".
               """

        refute entry.current == entry.recorded,
               "the report has to carry what the analyzer saw and what the file holds now, and they must differ"

        refute Fixtures.coverage_fresh?(context.scope, "exunit")

        {:ok, context}
      end
    end
  end
end
