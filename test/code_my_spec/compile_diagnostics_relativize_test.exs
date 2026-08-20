defmodule CodeMySpec.CompileDiagnosticsRelativizeTest do
  @moduledoc """
  A compiler diagnostic's paths leave `Compile` relative to the root it ran under.

  `CodeMySpec.BddSpecs.Spex.relativize_error_file/2` is this fix for the spex
  path (`cc643bf3`, `fa76604b`). The compiler path never got it, and the
  consequence is a loop rather than a cosmetic inconsistency:

    * `clear_problems_for_missing_files/2` deletes any Problem whose path is not
      in the current file list, and that list is relative — so an absolute row is
      removed on the next sync as though its file had been deleted;
    * the stop hook has already blocked on it by then;
    * the next compile writes a fresh absolute row.

  So the finding is real, `list_problems` cannot see it, the agent is told to fix
  something it cannot look up, and the block returns on the next sweep. Seven
  agents in one evening reported that symptom (b4c34f92 collects them, with
  3994cd2c, 042e343b, 339725c7, b10c4b46, 2071faa6 and a9e9caca).

  `Analysis.Reconciler.patch_file_path/1` already sees the bad row and warns —
  deliberately only warning, since rejecting would roll back every other problem
  from the same source. This makes the warning stop firing rather than making it
  louder.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Compile

  defp diagnostic(path) do
    %{
      "message" => "** (TokenMissingError) token missing",
      "position" => %{"line" => 1, "column" => 22},
      "file" => path,
      "source" => path,
      "severity" => "error",
      "compiler_name" => "Elixir"
    }
  end

  describe "relativize_diagnostics/2" do
    # The environment that actually produces absolute paths.
    # `Container.create/1` sets `cwd` to the container's own workdir, which is
    # the prefix its compiler reports under.
    test "a container's workdir-rooted paths come back relative" do
      [result] =
        Compile.relativize_diagnostics([diagnostic("/workspace/lib/example.ex")], "/workspace")

      assert result["file"] == "lib/example.ex"

      assert result["source"] == "lib/example.ex",
             "`source` joins nothing on its own, but it is stored alongside `file` " <>
               "and a half-relativized diagnostic is the kind that gets fixed twice"
    end

    test "a local checkout's absolute paths come back relative" do
      [result] =
        Compile.relativize_diagnostics(
          [diagnostic("/Users/someone/my_app/lib/example.ex")],
          "/Users/someone/my_app"
        )

      assert result["file"] == "lib/example.ex"
    end

    test "paths that are already relative are untouched" do
      [result] = Compile.relativize_diagnostics([diagnostic("lib/example.ex")], "/workspace")

      assert result["file"] == "lib/example.ex"
    end

    # `Path.relative_to/2` leaves a path under some other root alone, and that is
    # the right answer here: guessing a suffix would attribute a finding to a
    # file that merely shares a name. The reconciler's warning still catches it.
    test "a path under some other root stays absolute" do
      [result] = Compile.relativize_diagnostics([diagnostic("/elsewhere/lib/example.ex")], "/workspace")

      assert result["file"] == "/elsewhere/lib/example.ex"
    end

    test "a diagnostic with no file survives" do
      # `extract_compiler_errors/1`'s fallback shape: recovered from raw stdout,
      # message and severity only.
      recovered = %{"message" => "** (CompileError) oops", "severity" => "error"}

      assert Compile.relativize_diagnostics([recovered], "/workspace") == [recovered]
    end

    test "without a cwd nothing is guessed at" do
      diagnostics = [diagnostic("/workspace/lib/example.ex")]

      assert Compile.relativize_diagnostics(diagnostics, nil) == diagnostics
    end
  end
end
