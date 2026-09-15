defmodule CodeMySpec.Analysis.ARunRecordsWhatItReadTest do
  @moduledoc """
  A completed run has to leave behind what it read, and only what it read.

  `CoverageTest` covers the table's own behaviour. This covers the wiring —
  that `Reconciler.reconcile/4` records coverage at all, which nothing did
  until now: `Coverage` was built additively and its own moduledoc said
  "nothing consumes this yet". The table had zero rows in production.

  These run without backdating anything: the files are written, the run starts
  and the edit lands inside the same second. That is the point — `files.updated_at`
  carries microseconds since `20260915003000`, so a file can be ordered against
  the run that read it. At second precision none of this was decidable and
  coverage had to discard the whole second to stay honest.

  Criteria 3481 and 3483 on story 874. The second is the one that constrains
  the design: a file edited while the run was in flight must not be recorded at
  the content it now has, because the analyzer read the older bytes. Leaving it
  out is the safe direction — no row means unread, and unread never reads as
  clean.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  alias CodeMySpec.Analysis.{Coverage, Reconciler, RunsRepository}
  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "a working copy", device: device_fixture(scope))

    %{scope: %{scope | active_working_copy_id: copy.id}}
  end

  defp put_file(scope, path, fingerprint) do
    {_n, _} =
      Files.upsert_files(scope, [
        %{
          path: path,
          role: :implementation,
          fingerprint: fingerprint,
          mtime: DateTime.utc_now(),
          size: 10
        }
      ])

    :ok
  end

  defp clean_result do
    %{problems: [], output: "", exit_status: 0, stats: %{}}
  end

  defp covered_paths(scope, source) do
    scope
    |> Coverage.unanalyzed_files(source)
    |> Enum.map(& &1.path)
    |> Enum.sort()
  end

  test "a completed run records the files it read", ctx do
    :ok = put_file(ctx.scope, "lib/app/a.ex", "aaa")
    :ok = put_file(ctx.scope, "lib/app/b.ex", "bbb")

    {:ok, run} = RunsRepository.start_run(ctx.scope, %{source: "exunit", kind: :full})
    {:ok, _finished} = Reconciler.reconcile(ctx.scope, run, clean_result())

    assert covered_paths(ctx.scope, "exunit") == [],
           """
           A run completed and recorded nothing it read.

           Without a coverage row, a file with no findings and a file nobody
           analysed are the same shape — and `count == 0` reads clean out of an
           absence, which is the invariant this table exists to hold.
           """
  end

  test "a file edited while the run was in flight is not recorded as read", ctx do
    :ok = put_file(ctx.scope, "lib/app/untouched.ex", "aaa")
    :ok = put_file(ctx.scope, "lib/app/edited.ex", "bbb")

    {:ok, run} = RunsRepository.start_run(ctx.scope, %{source: "exunit", kind: :full})

    # The edit lands after the run began, so what the analyzer read is not what
    # this file now holds.
    :ok = put_file(ctx.scope, "lib/app/edited.ex", "bbb-changed")

    {:ok, _finished} = Reconciler.reconcile(ctx.scope, run, clean_result())

    assert covered_paths(ctx.scope, "exunit") == ["lib/app/edited.ex"],
           """
           The file edited mid-run was recorded as read at content the analyzer
           never saw — or the untouched one was not recorded at all.

           Recording the current fingerprint for a file whose older bytes were
           read stores a false fact permanently, which is worse than a stale one
           because nothing later contradicts it. Omitting it leaves it unread,
           and unread is the honest answer.
           """
  end

  test "a run that failed records nothing", ctx do
    :ok = put_file(ctx.scope, "lib/app/a.ex", "aaa")

    {:ok, run} = RunsRepository.start_run(ctx.scope, %{source: "exunit", kind: :full})
    {:ok, _failed} = Reconciler.fail(run, :crashed)

    assert covered_paths(ctx.scope, "exunit") == ["lib/app/a.ex"],
           "a run that produced no results must not leave coverage claiming it read anything"
  end
end
