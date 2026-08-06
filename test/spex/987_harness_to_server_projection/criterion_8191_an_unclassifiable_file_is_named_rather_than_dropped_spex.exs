defmodule CodeMySpecSpex.Story987.Criterion8191Spex do
  @moduledoc """
  Story 987 — Harness-to-Server Projection
  Criterion 8191 — An unclassifiable file is named rather than dropped.

  Covers Rule "A file the harness cannot classify is named in the harness log,
  never dropped in silence."

  This is the criterion that exists because of what the silence cost. An
  unclassified file never syncs, so the scan reports a constant file count while
  the agent keeps writing — indistinguishable from a dead file watcher. Four
  drills reached that conclusion; two spent their remaining time trying to
  revive watchers that were scanning every forty-five seconds and having every
  manifest accepted.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A file the harness cannot place is reported, not silently dropped" do
    scenario "a file matching no role is named as unsynced" do
      given_ "a file under a sync root that matches no role", context do
        :ok =
          Environments.write_file(
            context.environment,
            "test/support/some_helper.ex",
            "defmodule SomeHelper do\nend\n"
          )

        {:ok, context}
      end

      when_ "the harness scans the working copy", context do
        {:ok, Map.put(context, :skipped, Fixtures.unclassified_files(context.scope))}
      end

      then_ "the harness names that file as unsynced", context do
        assert "test/support/some_helper.ex" in context.skipped,
               """
               A file the scan walked past has to be nameable. Reporting only the
               count of what was taken makes a classification gap look exactly
               like a dead watcher, and that mistake has cost four drills.
               """

        {:ok, context}
      end
    end

    scenario "a file that does classify is not reported as skipped" do
      given_ "an implementation file the classifier recognises", context do
        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/tasks.ex",
            "defmodule MyApp.Tasks do\nend\n"
          )

        {:ok, context}
      end

      when_ "the harness scans the working copy", context do
        {:ok, Map.put(context, :skipped, Fixtures.unclassified_files(context.scope))}
      end

      then_ "it is absent from the skipped list", context do
        refute "lib/my_app/tasks.ex" in context.skipped,
               "a report that names tracked files too is noise nobody will read"

        {:ok, context}
      end
    end
  end
end
