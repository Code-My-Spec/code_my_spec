defmodule CodeMySpec.RecordingLock do
  @moduledoc """
  A marker saying a cassette recording session owns this working copy.

  `5a1f6b9c`. The stop hook queues a spex rerun on every stop. A recording
  session is not an ordinary test run, and a second suite landing on top of one
  is destructive in three separate ways:

    * It rewrites `test/cassettes/*.json`, which the replaying run reads. A
      replay that lands mid-rewrite fails on a half-written cassette and
      reports failures describing nothing about the code.
    * It talks to real providers and waits on real DNS propagation. A second
      suite saturating the machine times those waits out, which surfaces as a
      provider fault rather than as contention.
    * Recording renames each cassette to `.bak` once per run. Two runs clearing
      the same cassette means the second overwrites the first's backup, so the
      original survives only in git.

  Observed: two overlapping recording runs tore down each other's published
  records for ten minutes and corrupted 21 cassettes. The harness's queued
  rerun would have been a third participant, and there was no way to tell it to
  hold off.

  ## Why a file, and why the pid

  The two sides are different OS processes — the recording BEAM and the harness
  — so nothing in-memory can be shared. The file carries the recorder's OS pid
  because **a stale lock must not be believed**: a recording session killed
  before its `at_exit` leaves the file behind, and a lock that outlives its
  holder would disable the spex analyzer permanently. That is a worse failure
  than the collision it prevents, and this codebase has a run of issues about
  exactly that shape — a guard that wedges and whose own remedy cannot clear it.

  So the reader checks liveness and treats a dead holder as no lock at all.
  Pid recycling can in principle make a dead recorder look live; the cost is one
  skipped sweep with a message naming the pid, which is visible and recoverable.
  ## Its own boundary

  A leaf utility with no dependencies, reachable from both sides that need it:
  `CmsHarness` reads it and `CodeMySpecSpex` writes it, and those two cannot see
  each other or share anything in `CodeMySpec` proper. `CodeMySpec.TempFile` is
  the same shape and the precedent — a top-level boundary with `deps: []`, named
  explicitly in the spex boundary's list rather than reached through the
  fixtures bridge.
  """

  use Boundary, top_level?: true, deps: [], exports: :all

  @lock ".cms_recording.lock"

  @doc """
  Take the lock for this VM, releasing it when the VM exits.

  Idempotent per BEAM **per root**, matching `clear_cassette_once/2`, which keys
  on `{dir, name}` rather than a bare flag — "this `mix spex` run" without
  anything to start or supervise.

  Keyed on the root rather than a single flag because a bare flag makes the
  first call in a VM the only one that does anything, whatever root it was
  given. Production never notices, since a BEAM serves one working copy; two
  tests holding two different temp roots notice immediately, and the second one
  silently writes no file. That is the same shape as the collisions this module
  exists to prevent, one level up.

  `System.at_exit` rather than `on_exit`: the lock spans the whole recording
  session, not one spex, and a per-test callback would drop it between files
  and hand the harness a window it would take.
  """
  @spec hold(Path.t()) :: :ok
  def hold(root) do
    key = {__MODULE__, :held, root}

    case :persistent_term.get(key, :fresh) do
      :held ->
        :ok

      :fresh ->
        :persistent_term.put(key, :held)
        path = path(root)
        File.write!(path, "#{System.pid()}\n#{DateTime.utc_now() |> DateTime.to_iso8601()}\n")
        System.at_exit(fn _ -> File.rm(path) end)
        :ok
    end
  end

  @doc """
  Who holds the lock on `root`, if anyone.

  `{:held, pid, started_at}` when a live process holds it, `:free` otherwise —
  no file, an unreadable one, or a holder that is gone.
  """
  @spec holder(Path.t()) :: {:held, String.t(), String.t()} | :free
  def holder(root) do
    with {:ok, contents} <- File.read(path(root)),
         [pid, started_at | _] <- contents |> String.split("\n") |> Enum.map(&String.trim/1),
         true <- pid != "",
         true <- alive?(pid) do
      {:held, pid, started_at}
    else
      _ -> :free
    end
  end

  @doc """
  Why the spex analyzer is standing down, or `nil` when it is not.

  Phrased for an agent reading a stop response: it says what is happening, that
  it is deliberate, and that it ends on its own.
  """
  @spec skip_reason(Path.t()) :: String.t() | nil
  def skip_reason(root) do
    case holder(root) do
      :free ->
        nil

      {:held, pid, started_at} ->
        "a cassette recording session holds this working copy (pid #{pid}, since " <>
          "#{started_at}). Spex is skipped rather than run: recording rewrites the " <>
          "cassettes a replay reads, and a second suite times out its provider waits. " <>
          "This clears when that run exits — nothing to fix here."
    end
  end

  @doc false
  @spec path(Path.t()) :: Path.t()
  def path(root), do: Path.join(root, @lock)

  # `kill -0` is the portable liveness question and asks nothing of the target.
  # Its output is discarded — only the exit status carries the answer, and a
  # permission error still means the process exists.
  defp alive?(pid) do
    case Integer.parse(pid) do
      {n, ""} when n > 0 -> match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
      _ -> false
    end
  end
end
