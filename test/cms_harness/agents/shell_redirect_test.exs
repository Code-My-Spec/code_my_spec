defmodule CmsHarness.Agents.ShellRedirectTest do
  @moduledoc """
  Issue 13f276fb: restricted bash (`-r`) refused every `>`/`>>`, including one
  aimed at the agent's own checkout, where writing a validation log is
  ordinary. John's decision: allow that one case.

  The command handed to bash never contains the redirect (`Shell` strips it
  and writes the output itself), so these also prove the other restricted-mode
  guards (`cd`, `PATH`) are not loosened along with it -- confirmed directly
  against a real `bash -rc` in the investigation, not re-asserted here since
  that is bash's own behavior, not this module's.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Agents.Shell

  @moduletag :tmp_dir

  test "a trailing redirect into the working copy writes the file, not the reply", %{
    tmp_dir: dir
  } do
    assert {:ok, reply} = Shell.run("echo hello > out.txt", dir, 5_000)

    assert reply =~ "Output written to"
    assert reply =~ "exit code: 0"
    refute reply =~ "hello", "the point of a redirect is that the output goes to the file"

    assert File.read!(Path.join(dir, "out.txt")) == "hello\n"
  end

  test "a second redirect (>>) appends instead of truncating", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "out.txt"), "first\n")

    assert {:ok, _} = Shell.run("echo second >> out.txt", dir, 5_000)

    assert File.read!(Path.join(dir, "out.txt")) == "first\nsecond\n"
  end

  test "a trailing 2>&1 is tolerated, since output here is already merged", %{tmp_dir: dir} do
    assert {:ok, reply} = Shell.run("echo hello > out.txt 2>&1", dir, 5_000)

    assert reply =~ "Output written to"
    assert File.read!(Path.join(dir, "out.txt")) == "hello\n"
  end

  test "a target outside the working copy is still refused", %{tmp_dir: dir} do
    outside = Path.join(dir, "../outside-#{System.unique_integer([:positive])}.txt")

    assert {:ok, message} = Shell.run("echo hello > ../#{Path.basename(outside)}", dir, 5_000)
    assert message =~ "restricted"
    refute File.exists?(outside)
  end

  test "a target starting with ~ is not treated as inside the copy", %{tmp_dir: dir} do
    assert {:ok, message} = Shell.run("echo hello > ~/out.txt", dir, 5_000)
    assert message =~ "restricted"
  end

  test "a second > left in the command is refused, not guessed at", %{tmp_dir: dir} do
    assert {:ok, message} = Shell.run("echo a > one.txt > two.txt", dir, 5_000)
    assert message =~ "restricted"
    refute File.exists?(Path.join(dir, "one.txt"))
    refute File.exists?(Path.join(dir, "two.txt"))
  end

  test "with no working directory, redirection is never attempted" do
    assert {:ok, message} = Shell.run("echo hello > out.txt", nil, 5_000)
    assert message =~ "restricted"
  end

  test "a command with no redirect behaves as before", %{tmp_dir: dir} do
    assert {:ok, "hi\n\nexit code: 0"} = Shell.run("echo hi", dir, 5_000)
  end

  test "cd is still refused inside a command whose redirect is allowed", %{tmp_dir: dir} do
    assert {:ok, reply} = Shell.run("cd / && pwd > out.txt", dir, 5_000)

    assert reply =~ "exit code: 1",
           "cd && pwd should fail at cd (short-circuiting pwd), same as any other command " <>
             "under -r: #{inspect(reply)}"

    assert File.read!(Path.join(dir, "out.txt")) =~ "restricted",
           "cd must still be refused by bash itself, same as in any other command"
  end
end
