defmodule CodeMySpec.BddSpecs.SpexPathShapeTest do
  @moduledoc """
  A spex failure leaves the harness with a path relative to the working copy.

  `cc643bf3`: `Runners.spex_location/1` normally takes the file from a
  stacktrace frame, which is already relative. Its fallback — a failure with no
  `_spex.exs` frame at all, which is what `** (EXIT from #PID<…>) an exception
  was raised` produces when a linked LiveView dies — reads `error.file`, and
  that arrives absolute.

  The cost is not cosmetic. `clear_problems_for_missing_files/2` deletes every
  Problem whose path is not in the current file list, and that list is relative,
  so an absolute-path row is removed on the next sync as though its file had
  been deleted from the working copy. Four failures were observed doing exactly
  that: present in one query, gone from the next, with the spex still failing
  in between. A finding that clears itself is the quiet version of a gate that
  stops blocking.

  It also costs the component link and the "(not edited by this session)"
  attribution, which both join on relative paths.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.BddSpecs.Spex
  alias CodeMySpec.BddSpecs.Spex.{Error, Failure}

  @root "/Users/dev/project"

  defp failure_with(file) do
    %Failure{
      spex: "A spex",
      scenario: "A scenario",
      steps: [],
      error: %Error{message: "boom", file: file, line: 26, stacktrace: []}
    }
  end

  defp relativized(file) do
    Spex.relativize_error_file(failure_with(file), @root).error.file
  end

  describe "relativize_error_file/2" do
    test "makes an absolute path relative to the working copy root" do
      assert relativized("#{@root}/test/spex/816_mail/criterion_6580_spex.exs") ==
               "test/spex/816_mail/criterion_6580_spex.exs"
    end

    test "leaves an already-relative path alone" do
      assert relativized("test/spex/816_mail/criterion_6580_spex.exs") ==
               "test/spex/816_mail/criterion_6580_spex.exs"
    end

    # A failure that never reached a file — the shape `spec_file_fallback/1`
    # answers with `{nil, nil}`. Relativizing must not invent a path for it.
    test "leaves a failure with no file alone" do
      assert relativized(nil) == nil
    end

    test "leaves a failure with no error at all alone" do
      failure = %Failure{spex: "A spex", scenario: "A scenario", steps: [], error: nil}

      assert Spex.relativize_error_file(failure, @root) == failure
    end

    # A path outside the working copy stays absolute rather than becoming a
    # chain of `..` segments that matches nothing and reads as a path into
    # another checkout. `Path.relative_to/2` returns the original in that case,
    # which is the behaviour worth pinning.
    test "leaves a path outside the working copy absolute" do
      assert relativized("/tmp/elsewhere/criterion_spex.exs") ==
               "/tmp/elsewhere/criterion_spex.exs"
    end
  end
end
