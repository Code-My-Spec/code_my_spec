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
end
