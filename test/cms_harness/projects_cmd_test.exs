defmodule CmsHarnessTest.ProjectsCmdTest do
  @moduledoc """
  The setup helper's failure has to say what failed.

  `0bc611c9` is four tests that shell out to `mix` while three worktrees' suites
  and the harness's analyzers share the box, and its point is that the cost is
  not the flake but the diagnosis: each "presents as a specific failure in a
  named file and reads as a real defect in code nobody touched".

  `{_, 0} = System.cmd(…)` is the worst version of that. It raises a MatchError
  whose message is the tuple, with the command's own explanation truncated
  inside a value nobody prints, from a `setup` whose failure is then reported
  against whichever test happened to run first.

  Asserting the message rather than trusting it: a helper written to improve an
  error is worth exactly what its error actually says.
  """

  use ExUnit.Case, async: true

  import CmsHarnessTest.Projects, only: [cmd!: 3]

  test "a command that succeeds is quiet" do
    assert cmd!(System.tmp_dir!(), "sh", ["-c", "exit 0"]) == :ok
  end

  test "a command that fails raises with its output, its status and its directory" do
    error =
      assert_raise RuntimeError, fn ->
        cmd!(System.tmp_dir!(), "sh", ["-c", "echo 'could not fetch dependency' >&2; exit 17"])
      end

    assert error.message =~ "could not fetch dependency"
    assert error.message =~ "exited 17"
    assert error.message =~ System.tmp_dir!()
  end

  # The sentence that stops the next agent bisecting its own work, which is the
  # whole reason the issue was filed rather than the flake dismissed as noise.
  test "it says setup failures here are often contention" do
    error =
      assert_raise RuntimeError, fn ->
        cmd!(System.tmp_dir!(), "sh", ["-c", "exit 1"])
      end

    assert error.message =~ "not its subject"
    assert error.message =~ "contention"
    assert error.message =~ "idle box"
  end
end
