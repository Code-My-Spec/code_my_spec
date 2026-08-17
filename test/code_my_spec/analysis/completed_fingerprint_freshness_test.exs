defmodule CodeMySpec.Analysis.CompletedFingerprintFreshnessTest do
  @moduledoc """
  A run's answer describes the tree it finished against, not the one it was
  asked about.

  Two fingerprints are recorded on every run and only one was ever read.
  `input_fingerprint` is stamped at enqueue; `completed_fingerprint` at
  reconcile, where the comment has called it "the tree this answered about"
  since `7a7eed33`. Nothing consumed it.

  Judging on input alone does not converge under the ordinary sequence — edit,
  a stop enqueues a run, keep working, the run reads the edited files and
  finishes. The run is then permanently stale against a tree that no longer
  exists, and the run enqueued to replace it is invalidated the same way by the
  next edit. For any analyzer slower than the edit rate this is a gate that
  cannot be passed by doing the work correctly.

  Story 896 hit it: seven spex green across four sweeps, and `bdd_specs_passing`
  could not latch, because implementing the code that made the specs pass was
  itself what invalidated the run proving they passed. `Coverage`'s moduledoc
  records the same trap for exunit at ~2m20s.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.{Fingerprint, RunsRepository}
  alias CodeMySpec.Files

  defp run(scope, attrs) do
    {:ok, r} =
      RunsRepository.start_run(scope, Map.merge(%{source: "credo", kind: :full}, attrs))

    r
  end

  defp finish(run, attrs \\ %{}), do: RunsRepository.finish_run(run, :completed, attrs)

  defp put_impl(scope, fingerprint) do
    Files.upsert_files(scope, [
      %{
        path: "lib/a.ex",
        role: :implementation,
        fingerprint: fingerprint,
        mtime: DateTime.utc_now() |> DateTime.truncate(:microsecond),
        size: 1
      }
    ])

    Fingerprint.current(scope, "credo")
  end

  describe "fresh?/2" do
    test "a run that finished against the current tree is fresh" do
      scope = full_scope_fixture()

      asked_about = put_impl(scope, "fp-old")
      # The edit lands while the run is in flight.
      current = put_impl(scope, "fp-new")

      scope
      |> run(%{input_fingerprint: asked_about})
      |> finish(%{completed_fingerprint: current})

      assert Analysis.fresh?(scope, "credo"),
             """
             The run read the edited file and finished against this tree. Judging
             it by the fingerprint it was *asked* about marks it stale forever,
             and its replacement is invalidated by the next edit the same way.
             """
    end

    test "a run whose input still matches is fresh, with no completed stamp" do
      scope = full_scope_fixture()
      current = put_impl(scope, "fp-1")

      scope |> run(%{input_fingerprint: current}) |> finish()

      assert Analysis.fresh?(scope, "credo"),
             "nothing moved between ask and now; older rows carry no completed stamp"
    end

    test "a run that answered about a tree nobody is looking at is stale" do
      scope = full_scope_fixture()
      old = put_impl(scope, "fp-1")

      scope
      |> run(%{input_fingerprint: old})
      |> finish(%{completed_fingerprint: old})

      put_impl(scope, "fp-2")

      refute Analysis.fresh?(scope, "credo"),
             "neither fingerprint describes the tree now, so the answer is unknown"
    end
  end

  describe "fresh_sources/2" do
    test "agrees with fresh?/2 about the same run" do
      scope = full_scope_fixture()

      asked_about = put_impl(scope, "fp-old")
      current = put_impl(scope, "fp-new")

      scope
      |> run(%{input_fingerprint: asked_about})
      |> finish(%{completed_fingerprint: current})

      assert MapSet.member?(Analysis.fresh_sources(scope, ["credo"]), "credo"),
             "the batch path and the single path must not disagree about one run"
    end
  end
end
