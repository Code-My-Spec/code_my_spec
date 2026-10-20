defmodule CodeMySpec.LandingHoldTest do
  @moduledoc """
  Issue a4753b66: `rm -f .git/landing_hold` in the `serve` and `reload` recipes
  exits 1 where `.git` is a file (every git worktree), which stopped every working
  copy's app from restarting. The marker's path comes from the checkout's git
  directory, the recipes ask git for the same path, and these keep the three
  agreeing.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.LandingHold

  @moduletag :tmp_dir

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp repo_with_worktree(dir) do
    main = Path.join(dir, "main")
    worktree = Path.join(dir, "copy")
    File.mkdir_p!(main)

    {_, 0} = git(main, ["init", "--initial-branch=main"])
    {_, 0} = git(main, ["config", "user.email", "t@example.com"])
    {_, 0} = git(main, ["config", "user.name", "T"])
    File.write!(Path.join(main, "f.txt"), "x\n")
    {_, 0} = git(main, ["add", "."])
    {_, 0} = git(main, ["commit", "-m", "base"])
    {_, 0} = git(main, ["worktree", "add", worktree, "-b", "copy"])
    {main, worktree}
  end

  test "an ordinary checkout keeps the marker in its .git directory", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, ".git"))

    assert LandingHold.marker_path(dir) == Path.join(dir, ".git/landing_hold")
  end

  test "a checkout that is not there falls back to .git", %{tmp_dir: dir} do
    assert LandingHold.marker_path(Path.join(dir, "nowhere")) ==
             Path.join(dir, "nowhere/.git/landing_hold")
  end

  test "a worktree, whose .git is a file, keeps it where that file points", %{tmp_dir: dir} do
    {_main, worktree} = repo_with_worktree(dir)
    assert File.regular?(Path.join(worktree, ".git"))

    path = LandingHold.marker_path(worktree)

    refute path == Path.join(worktree, ".git/landing_hold")
    assert File.dir?(Path.dirname(path))
  end

  test "it is the path git itself gives, in a checkout and in a worktree", %{tmp_dir: dir} do
    {main, worktree} = repo_with_worktree(dir)

    for root <- [main, worktree] do
      {out, 0} = git(root, ["rev-parse", "--git-path", "landing_hold"])
      git_path = out |> String.trim() |> Path.expand(root) |> real()

      assert real(LandingHold.marker_path(root)) == git_path
    end
  end

  test "the recipes' removal exits 0 in a worktree, with or without a marker", %{tmp_dir: dir} do
    {_main, worktree} = repo_with_worktree(dir)
    line = ~S|rm -f "$(git rev-parse --git-path landing_hold)"|

    assert {_, 0} = System.cmd("sh", ["-c", line], cd: worktree)

    File.write!(LandingHold.marker_path(worktree), "1")
    assert {_, 0} = System.cmd("sh", ["-c", line], cd: worktree)
    refute File.exists?(LandingHold.marker_path(worktree))
  end

  test "the justfile removes the marker through git, not through a .git directory" do
    justfile = File.read!("justfile")

    refute justfile =~ "rm -f .git/landing_hold"
    assert justfile =~ ~S|rm -f "$(git rev-parse --git-path landing_hold)"|
  end

  # /var and /private/var are one place on macOS.
  defp real(path) do
    {out, 0} = System.cmd("realpath", [Path.dirname(path)])
    Path.join(String.trim(out), Path.basename(path))
  end
end
