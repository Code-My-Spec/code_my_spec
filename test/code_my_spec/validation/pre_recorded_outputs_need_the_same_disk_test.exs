defmodule CodeMySpec.Validation.PreRecordedOutputsNeedTheSameDiskTest do
  @moduledoc """
  `test_output_files` on a working copy this server does not hold.

  The parameter lets a cassette-backed spec drive the pipeline with known
  outputs, because `System.cmd`'s real side effects — the JSON files the
  analyzers write — are not something `ExCliVcr` can capture. It names paths on
  the machine running the pipeline.

  On a harness-held copy the pipeline runs on the *other* machine, so those
  paths name files that are not there. That was not refused; it was dropped.
  QA posted to `/api/hooks/stop` with absolute fixture paths, got back the
  ordinary "analysis running: compiler, credo, exunit, spex — results apply next
  stop", waited ninety seconds, re-posted, and still found no spex problems on
  that copy — every symptom of a slow or stuck analyzer, and none of a parameter
  that was read and discarded. Issue `5151df37`.

  Worth naming what it was not: the report's hypothesis was a `Mix.env()` gate.
  `Hooks.Stop.extract_test_output_files/1` has no such gate and never did — it
  extracts in every environment, and the local path honours what it extracts.
  The split is which machine holds the disk, which is why the refusal lives
  beside that branch rather than behind an environment check.

  ## What is deliberately not here

  A stop with no fixtures, asserted to go through. Running it means running the
  non-refused remote path, which dispatches real analyzers -- the run reached
  `mix` and came back `{:test_suite_did_not_run, 1, "Could not find a
  Mix.Project"}`, a live shell-out this suite does not allow. Both refusals
  below already distinguish the two cases by construction: the guard is
  `Keyword.take(opts, @test_output_file_opts)`, so "no fixtures supplied" is the
  empty list and cannot be confused with a supplied one.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Validation

  # A stand-in for the harness channel: the registry holds the channel process,
  # so registering one is what makes the harness addressable — and what sends
  # `validate_stop/3` down the remote branch rather than the empty answer.
  defp registered_channel(working_copy_id) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Analysis.register_executor(working_copy_id, "test:#{System.unique_integer()}")
        send(test, {:registered, self()})

        receive do
          message -> send(test, {:channel_got, message})
        end
      end)

    assert_receive {:registered, ^pid}, 1_000
    pid
  end

  setup do
    # A real working copy, not a label. The path that is *not* refused records an
    # analysis run against this id, and `analysis_runs.harness_id` is a foreign
    # key -- so a stand-in string fails to cast, and a bare uuid fails the
    # constraint, both of them long before reaching anything this file is about.
    base = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(base, nil,
        label: "a checkout on another machine",
        device: device_fixture(base)
      )

    scope = %{base | active_working_copy_id: copy.id, cwd: nil}

    %{scope: scope, working_copy_id: copy.id}
  end

  test "supplying pre-recorded outputs to a harness-held copy is refused, not ignored", ctx do
    _pid = registered_channel(ctx.working_copy_id)

    assert {:error, reason, nil} =
             Validation.validate_stop(ctx.scope, nil,
               spex_output_file: "/tmp/spex.jsonl",
               compile_output_file: "/tmp/compile.jsonl"
             ),
           """
           `test_output_files` was accepted on a path that cannot honour it.

           Silently dropping it is worse than refusing: the stop dispatches a
           real analyzer run and answers "results apply next stop", which is
           indistinguishable from an analyzer that is merely slow. QA spent
           ninety seconds and several re-posts on that before concluding the
           endpoint was stuck.
           """

    assert reason =~ "analyzers run", reason
    assert reason =~ "wrong machine", reason

    assert reason =~ ":spex_output_file" and reason =~ ":compile_output_file",
           """
           The refusal does not say which options it is about.

           A caller passing four fixtures needs to know these two were the
           problem, not to re-derive it — the whole defect being fixed is a
           message that did not mention the parameter at all.

           #{reason}
           """
  end

  test "nothing is dispatched to the harness when it is refused", ctx do
    _pid = registered_channel(ctx.working_copy_id)

    assert {:error, _reason, nil} =
             Validation.validate_stop(ctx.scope, nil, exunit_output_file: "/tmp/exunit.json")

    refute_receive {:channel_got, _anything}, 200

    # The claim the refusal makes is "nothing was run and nothing was recorded".
    # A refusal that had already started a real run would be a worse answer than
    # the silence it replaces, because the caller would then be told to expect
    # nothing while results landed anyway.
  end
end
