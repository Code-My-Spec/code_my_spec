defmodule CodeMySpec.Analysis.StaleRerunLivelockTest do
  @moduledoc """
  A source the stop hook calls stale must not be skipped as current.

  Two functions answered "is this result good?" from different evidence.
  `Analysis.fresh_sources/2` compares the latest *completed* run's
  `input_fingerprint` to the tree now. `needs_run?/5` under `only_failed` looked
  at the run's **status alone** — completed meant current, whatever the tree had
  done since.

  `run_pipeline/5` passes `only_failed: true` whenever the turn recorded no
  changed files, which is the ordinary case for a stop that follows an edit
  already synced on a previous stop. So both were reachable at once, and they
  contradicted:

      [Analysis] skipped (current): compiler, credo, exunit, spex

      credo (1) — stale, last ran 19m ago:
        - …devops_status.ex:32 — `with` contains only one <- clause
      A rerun is in flight now (credo) — stop again and let it replace these.

  Nothing was in flight. The hook's advice — "do not re-fix anything you have
  already corrected, stop again and let it replace these" — is correct and
  cannot succeed, so following it loops forever, and the alternative is editing
  code that is already right. `1f60a145`.

  The fix is that both read the fingerprint. `only_failed` still means "do not
  redo work for an unchanged tree"; it no longer means "an unchanged *status* is
  proof the tree is unchanged".
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{Fingerprint, RunsRepository}
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, "lib/my_app/a.ex"), "defmodule MyApp.A do\nend\n")
    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    %{scope: scope, tmp: tmp}
  end

  defp plan(scope, sources) do
    Analysis.plan_runs(
      sources,
      Fingerprint.current(scope),
      RunsRepository.latest_full_runs(scope),
      true
    )
  end

  defp completed_run(scope, source, fingerprint) do
    {:ok, run} = RunsRepository.start_run(scope, %{source: source, kind: :full})

    {:ok, run} =
      RunsRepository.finish_run(run, :completed, %{
        finished_at: DateTime.utc_now(),
        input_fingerprint: fingerprint
      })

    run
  end

  test "a completed run whose inputs have moved is re-run, not skipped", ctx do
    # Completed against the tree as it was.
    completed_run(ctx.scope, "credo", Fingerprint.current(ctx.scope, "credo"))

    # The tree moves — this is the edit the agent just made and the reason the
    # hook will call the result stale.
    File.write!(Path.join(ctx.tmp, "lib/my_app/a.ex"), "defmodule MyApp.A do\n  def go, do: :ok\nend\n")
    {:ok, _} = FileSync.sync(ctx.scope, base_dir: ctx.tmp)

    refute MapSet.member?(Analysis.fresh_sources(ctx.scope, ["credo"]), "credo"),
           "precondition: the stop hook considers this stale"

    {stale, _memoized} = plan(ctx.scope, ["credo"])

    assert "credo" in Enum.map(stale, &elem(&1, 0)),
           "the hook says stale and promises a rerun; skipping it as current is " <>
             "what makes that promise unkeepable"
  end

  test "a completed run whose inputs have not moved is still skipped", ctx do
    completed_run(ctx.scope, "credo", Fingerprint.current(ctx.scope, "credo"))

    assert MapSet.member?(Analysis.fresh_sources(ctx.scope, ["credo"]), "credo")

    {_stale, memoized} = plan(ctx.scope, ["credo"])

    assert "credo" in Enum.map(memoized, &elem(&1, 0)),
           "`only_failed` still means do not redo work for an unchanged tree — " <>
             "that is the whole point of it and must survive the fix"
  end
end
