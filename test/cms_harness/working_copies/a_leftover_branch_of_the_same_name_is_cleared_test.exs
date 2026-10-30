defmodule CmsHarness.WorkingCopies.ALeftoverBranchOfTheSameNameIsClearedTest do
  @moduledoc """
  Gate worktrees removed without their branches left promotion-gate-* branches,
  and every new gate's `git worktree add -b` failed on "a branch named …
  already exists".
  """
  use ExUnit.Case, async: true

  alias CmsHarness.WorkingCopies.Create

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    File.mkdir_p!(root)
    git!(root, ["init", "-q", "-b", "main"])
    git!(root, ["config", "user.email", "a@b.c"])
    git!(root, ["config", "user.name", "a"])
    File.write!(Path.join(root, "README.md"), "hi\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "init"])
    %{root: root, dir: dir}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp branch?(root, name),
    do:
      match?(
        {_, 0},
        System.cmd("git", ["-C", root, "rev-parse", "--verify", "refs/heads/" <> name])
      )

  test "a leftover branch whose worktree is gone, with nothing of its own, is deleted", ctx do
    gone = Path.join(ctx.dir, "gone")
    git!(ctx.root, ["worktree", "add", "-q", "-b", "promotion-gate", gone])
    File.rm_rf!(gone)

    assert :ok = Create.clear_leftover_branch(ctx.root, "promotion-gate")
    refute branch?(ctx.root, "promotion-gate")
  end

  test "a leftover branch with commits of its own is kept and refused", ctx do
    git!(ctx.root, ["switch", "-q", "-c", "promotion-gate"])
    File.write!(Path.join(ctx.root, "work.ex"), "work\n")
    git!(ctx.root, ["add", "."])
    git!(ctx.root, ["commit", "-q", "-m", "work"])
    git!(ctx.root, ["switch", "-q", "main"])

    assert {:error, {:leftover_branch_has_commits, "promotion-gate"}} =
             Create.clear_leftover_branch(ctx.root, "promotion-gate")

    assert branch?(ctx.root, "promotion-gate")
  end

  test "no branch of that name is nothing to clear", ctx do
    assert :ok = Create.clear_leftover_branch(ctx.root, "promotion-gate")
  end
end
