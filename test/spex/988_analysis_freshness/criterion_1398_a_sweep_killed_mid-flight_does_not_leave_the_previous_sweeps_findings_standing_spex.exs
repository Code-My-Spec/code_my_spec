defmodule CodeMySpecSpex.Story988.Criterion3478Spex do
  @moduledoc """
  Story 988 — Analysis Freshness
  Criterion 3478 — A sweep killed mid-flight does not leave the previous
  sweep's findings standing.

  Root-caused 2026-09-15: four working copies each held a frozen batch of
  spex problems days old, on suites that had been green for hours. Not a
  clearing bug — `Reconciler.reconcile/4`'s clear-and-reinsert is
  unconditional and would wipe a zero-finding result too. The run never got
  there: `{:build_changed_mid_run, ...}` failed it first, and
  `Reconciler.fail/2` is deliberately silent on Problems — a crashed run
  answers nothing, so the previous set is left exactly as it was.

  Silent is the right call for the table. It is the wrong call for the agent
  reading it, if nothing says the sweep meant to replace what it is looking
  at never landed. The failure this criterion is about is presenting an old
  finding as though the sweep that would confirm or clear it actually ran.

  The label is the failed-rerun note: the newest run of the source failed, so
  the response says when and why, and that these findings are from the
  earlier run and were not re-checked. Since 28d72f8a there is no "stale"
  marker to carry it — the run's own record does. The failed run must not have
  quietly cleared or masked the finding it was meant to replace.
  """

  use CodeMySpecSpex.Case
  use ExCliVcr

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  # See criterion 3059's note: an uncassetted `validate_stop` runs a real
  # `mix compile` and a real recursive `mix spex`, which has nothing to do
  # with the credo finding this criterion is about.
  @validate_stop_opts [
    compile_output_file: Path.expand("test/fixtures/validation/pipeline_clean_run/compile.jsonl"),
    spex_output_file: Path.expand("test/fixtures/validation/spex_green.jsonl")
  ]

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on

  spex "A killed rerun does not resurrect the sweep it was meant to replace", criterion: 1398 do
    scenario "the corrected file's old finding survives the kill, marked stale" do
      given_ "a completed sweep recorded a finding and the agent fixed the file", context do
        Fixtures.set_analyzer_mode(context.scope, :credo, :block_all)

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/accounts.ex",
            "defmodule MyApp.Accounts do\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)
        Fixtures.record_problem(context.scope, "credo")
        Fixtures.fresh_analysis_runs(context.scope, ["credo"])

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_app/accounts.ex",
            "defmodule MyApp.Accounts do\n  # flattened\nend\n"
          )

        Fixtures.deliver_manifest(context.scope)

        {:ok, context}
      end

      when_ "the rerun credo enqueued to confirm the fix is killed before it reports", context do
        Fixtures.failed_analysis_run(context.scope, "credo")
        {:ok, context}
      end

      then_ "the old finding still blocks, and is not presented as current", context do
        result =
          use_cmd_cassette "clean", record: :none do
            Fixtures.validate_stop(context.scope, @validate_stop_opts)
          end

        assert {:error, message} = result,
               """
               A killed rerun must not read the same as a completed one that
               found nothing — the finding it was meant to confirm or clear
               is still open, and dropping it here is exactly how four
               working copies carried days-old problems on suites that had
               been green for hours.
               """

        assert message =~ "were not re-checked",
               """
               The rerun died without answering. Presenting this finding as
               current — as though the sweep that would confirm or clear it
               actually landed — is the failure mode this criterion exists
               to close.

               #{message}
               """

        {:ok, context}
      end
    end
  end
end
