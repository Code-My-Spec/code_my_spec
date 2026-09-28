defmodule CodeMySpecSpex.Story988.Criterion3481Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 3481 — A file no analyzer has read is not reported as clean.

  Covers Rule "An analyzer's silence about a file is not a clean verdict."

  `tests_passing` and `no_problems` are `count == 0`, and until `Coverage`
  existed that count could not tell a file with no findings apart from a
  file nobody had looked at — both are zero rows. `Coverage.unanalyzed_files/2`
  is the table built to hold that difference: a role that feeds an analyzer
  with no `file_analyses` row for it is answered as unread, not as clean.

  `Coverage`'s own moduledoc says nothing consumes this yet — this criterion
  is the read side of the table on its own terms, ahead of anything wiring
  it into `validate_stop`, the same way `ARunRecordsWhatItReadTest` proves
  the write side ahead of a consumer.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "Coverage answers 'read' and 'clean' as two different questions", criterion: 1401 do
    scenario "a file exunit has never read is named, not folded into clean" do
      given_ "a file exists whose role feeds exunit", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/untouched.ex",
            "defmodule MyApp.Untouched do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, context}
      end

      when_ "exunit has never run against this working copy", context do
        {:ok, context}
      end

      then_ "the file is reported as unread, and exunit is not fresh over it", context do
        unread = Fixtures.unread_files(context.scope, "exunit")

        assert Enum.any?(unread, &(&1.path == "lib/my_app/untouched.ex")),
               """
               A file with a feeding role and no coverage row must be named
               as unread. Silence about it is not the same claim as having
               looked and found nothing.
               """

        refute Fixtures.coverage_fresh?(context.scope, "exunit"),
               """
               `count == 0` on problems is not the same fact as `fresh? == true`
               — a source cannot answer for a file it has never read, and this
               is the invariant `count == 0` alone cannot express.
               """

        {:ok, context}
      end
    end
  end
end
