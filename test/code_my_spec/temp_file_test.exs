defmodule CodeMySpec.TempFileTest do
  @moduledoc """
  The property that matters is one this suite cannot observe directly: two
  *separate OS processes* must not generate the same path.

  So these assert the ingredient that provides it — the OS pid in the name —
  rather than the guarantee itself. A test that only checked "two calls differ"
  would have passed against the implementation this replaces, which is exactly
  how the bug survived: `System.unique_integer/1` never repeats within a BEAM,
  and every test runs in one BEAM.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.TempFile

  doctest CodeMySpec.TempFile

  describe "path/2" do
    test "lands in the system temp directory" do
      assert TempFile.path("thing") |> Path.dirname() == System.tmp_dir!() |> Path.expand()
    end

    test "carries the prefix and suffix it was given" do
      path = TempFile.path("compile_diagnostics", ".jsonl")

      assert Path.basename(path) =~ ~r/^compile_diagnostics_/
      assert String.ends_with?(path, ".jsonl")
    end

    # The ingredient that makes this cross-process unique. `System.unique_integer`
    # gave a name unique within one BEAM and the path is machine-wide, so two
    # suites — or a suite and the harness's analyzers — collided on
    # `compile_diagnostics_7.jsonl` and one read the other's diagnostics.
    test "includes the OS pid" do
      assert TempFile.path("thing") =~ System.pid()
    end

    test "two calls never collide" do
      paths = for _ <- 1..500, do: TempFile.path("thing", ".json")

      assert paths |> Enum.uniq() |> length() == 500
    end

    test "a suffix is optional" do
      refute TempFile.path("thing") =~ "."
    end
  end

  describe "dir/1" do
    test "is hyphenated, matching the existing cms-ssh style" do
      assert TempFile.dir("cms-ssh") |> Path.basename() =~ ~r/^cms-ssh-/
    end

    # Callers hand some of these to things that create the directory themselves
    # (ssh-keygen, docker), and creating it first changes their behaviour.
    test "does not create anything on disk" do
      path = TempFile.dir("cms-probe")

      refute File.exists?(path)
    end
  end

  describe "sweep_stale/2" do
    test "removes a prefixed directory older than max_age_ms" do
      stale = TempFile.dir("sweep-stale-test")
      File.mkdir_p!(stale)
      backdate!(stale, :timer.hours(2))

      TempFile.sweep_stale("sweep-stale-test", :timer.hours(1))

      refute File.exists?(stale)
    end

    test "leaves a prefixed directory that is not stale" do
      fresh = TempFile.dir("sweep-fresh-test")
      File.mkdir_p!(fresh)

      TempFile.sweep_stale("sweep-fresh-test", :timer.hours(1))

      assert File.exists?(fresh)
      File.rm_rf!(fresh)
    end

    # /tmp is shared by every prefix this module hands out; sweeping one
    # run's stale backlog must never reach into another's.
    test "leaves a stale directory carrying a different prefix" do
      other = TempFile.dir("sweep-other-test")
      File.mkdir_p!(other)
      backdate!(other, :timer.hours(2))

      TempFile.sweep_stale("sweep-stale-test", :timer.hours(1))

      assert File.exists?(other)
      File.rm_rf!(other)
    end

    test "leaves a stale file carrying the prefix alone" do
      stale_file = TempFile.path("sweep-file-test")
      File.write!(stale_file, "")
      backdate!(stale_file, :timer.hours(2))

      TempFile.sweep_stale("sweep-file-test", :timer.hours(1))

      assert File.exists?(stale_file)
      File.rm!(stale_file)
    end
  end

  describe "sweep_orphans/2" do
    test "removes an old entry whose creating process is gone" do
      orphan = dead_owner_dir("orphan-test")
      File.mkdir_p!(orphan)
      backdate!(orphan, :timer.minutes(20))

      TempFile.sweep_orphans(:timer.minutes(10))

      refute File.exists?(orphan)
    end

    test "leaves an entry whose creating process is alive" do
      owned = TempFile.dir("owned-test")
      File.mkdir_p!(owned)
      backdate!(owned, :timer.minutes(20))

      TempFile.sweep_orphans(:timer.minutes(10))

      assert File.exists?(owned)
      File.rm_rf!(owned)
    end

    test "leaves a recent entry even when its process is gone" do
      recent = dead_owner_dir("recent-test")
      File.mkdir_p!(recent)

      TempFile.sweep_orphans(:timer.minutes(10))

      assert File.exists?(recent)
      File.rm_rf!(recent)
    end
  end

  # macOS pids stay below 100_000, so this owner is never running.
  defp dead_owner_dir(prefix) do
    random = 9 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    Path.join(System.tmp_dir!(), "#{prefix}-999999999_1_#{random}")
  end

  defp backdate!(path, age_ms) do
    File.touch!(path, System.os_time(:second) - div(age_ms, 1000))
  end
end
