defmodule CodeMySpec.Promotion.AMergeRefusalSaysWhatGitSaidTest do
  @moduledoc """
  `git merge --ff-only` fails for more than one reason, and the refusal used to
  assert the same one every time.

  A dirty target is the other common one: git aborts with "would be overwritten
  by merge" and names the files, *while printing the fast-forward it was about
  to make*. Calling that "behind main" sends the reader to
  `git merge --ff-only main`, which is a no-op for it — so the remedy confirms
  the diagnosis by changing nothing and the next attempt fails identically.

  Measured on the math project 2026-09-22, one untracked `mix.lock` in the
  target. The coding agent verified `git merge-base --is-ancestor main sum`
  twice, ran the suggested merge twice, and filed a framework issue saying
  promote "looks like it is comparing against a stale or wrong reference rather
  than the actual git ancestry". It was reading the only evidence it had.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Promotion.Steps

  @dirty """
  error: The following untracked working tree files would be overwritten by merge:
  \tmix.lock
  Please move or remove them before you merge.
  Aborting
  Updating 96479a3..188b173
  """

  @behind """
  fatal: Not possible to fast-forward, aborting.
  """

  test "a dirty target names the files and says it is not a divergence" do
    {:error, %{reason: reason, output: output}} = Steps.merge_refusal("/some/root", "sum", @dirty)

    assert reason =~ "mix.lock",
           "the refusal has to name what is in the way; the reader cannot guess it"

    assert reason =~ "fast-forward",
           "git said this was a valid fast-forward and the refusal should not contradict it"

    refute reason =~ "behind main",
           """
           A dirty target was reported as a divergence.

           That is the failure this exists to stop: the suggested remedy is a
           no-op for it, so following the advice correctly changes nothing and
           the next attempt fails the same way.
           """

    assert output =~ "Updating 96479a3..188b173", "git's own words survive"
  end

  test "a real divergence still reads as one" do
    {:error, %{reason: reason}} = Steps.merge_refusal("/some/root", "sum", @behind)

    assert reason =~ "behind main",
           "narrowing the dirty case must not swallow the case it was written for"
  end
end
