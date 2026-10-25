defmodule CmsHarness.WorkingCopies.AnUnacknowledgedCreateRollsBackIfUntouchedTest do
  @moduledoc """
  68d37919: a create_working_copy whose reply the server never acknowledged
  (a crashed channel, a lost connection) left a worktree and identity file on
  disk with nothing on the server to show for it -- and a retry under the
  same label then hit `{:already_exists, target}` for a directory nobody
  could tell was an orphan rather than somebody's real work.

  `Create.rollback_if_untouched/3` is the harness's own half of making the
  create all-or-nothing: given the base commit captured right after the
  worktree was made, it removes the worktree only if nothing has touched it
  since -- no commit beyond that base, no change to a tracked file. An
  untracked file this same call wrote (the identity, onboarding's files)
  does not count against it.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.WorkingCopies.Create

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "root")
    File.mkdir_p!(root)
    git!(root, ["init", "-q"])
    git!(root, ["config", "user.email", "a@b.c"])
    git!(root, ["config", "user.name", "a"])
    File.write!(Path.join(root, "README.md"), "hi\n")
    git!(root, ["add", "."])
    git!(root, ["commit", "-q", "-m", "init"])

    target = Path.join(dir, "target")
    git!(root, ["worktree", "add", "-q", "-b", "a-copy", target])

    %{root: root, target: target}
  end

  defp git!(dir, args) do
    {out, 0} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    out
  end

  defp head(target) do
    {sha, 0} = System.cmd("git", ["-C", target, "rev-parse", "HEAD"], stderr_to_stdout: true)
    String.trim(sha)
  end

  test "removes the worktree when nothing has touched it since creation", %{
    root: root,
    target: target
  } do
    base_head = head(target)

    assert :ok = Create.rollback_if_untouched(root, target, base_head)
    refute File.exists?(target)
  end

  test "an untracked file this call itself would have written does not block rollback", %{
    root: root,
    target: target
  } do
    base_head = head(target)
    File.write!(Path.join(target, ".cms_harness.json"), "{}\n")

    assert :ok = Create.rollback_if_untouched(root, target, base_head)
    refute File.exists?(target)
  end

  test "leaves a worktree with a new commit beyond base alone", %{root: root, target: target} do
    base_head = head(target)

    File.write!(Path.join(target, "work.ex"), "defmodule Work do end\n")
    git!(target, ["add", "."])
    git!(target, ["commit", "-q", "-m", "work"])

    assert {:error, :not_untouched} = Create.rollback_if_untouched(root, target, base_head)
    assert File.exists?(target)
  end

  test "leaves a worktree with an uncommitted change to a tracked file alone", %{
    root: root,
    target: target
  } do
    base_head = head(target)
    File.write!(Path.join(target, "README.md"), "changed\n")

    assert {:error, :not_untouched} = Create.rollback_if_untouched(root, target, base_head)
    assert File.exists?(target)
  end

  test "a nil base_head (never captured) leaves the worktree alone", %{
    root: root,
    target: target
  } do
    assert {:error, :not_untouched} = Create.rollback_if_untouched(root, target, nil)
    assert File.exists?(target)
  end

  test "an orphan with work in it is refused, named as an orphan from a failed create",
       %{root: root, target: target} do
    File.write!(Path.join(target, ".cms_harness.json"), "{}\n")
    File.write!(Path.join(target, "work.ex"), "defmodule Work do end\n")
    git!(target, ["add", "work.ex"])
    git!(target, ["commit", "-q", "-m", "work"])

    assert {:error, {:orphaned_from_failed_create, ^target}} =
             Create.run(root, %{"label" => "x", "root" => target})
  end

  # 2de5dc77: a harness restarted mid-create left the gate copy behind and the
  # promotion queue wedged on the refusal.
  test "an untouched orphan is reclaimed, branch and all", %{root: root, target: target} do
    File.write!(Path.join(target, ".cms_harness.json"), "{}\n")
    File.write!(Path.join(target, ".cms_harness_preparing"), "preparing\n")

    assert :ok = Create.claim_target(root, target)
    refute File.exists?(target)
    refute git!(root, ["branch", "--list", "a-copy"]) =~ "a-copy"
  end

  test "an orphan with an uncommitted change to a tracked file is refused", %{
    root: root,
    target: target
  } do
    File.write!(Path.join(target, ".cms_harness.json"), "{}\n")
    File.write!(Path.join(target, "README.md"), "changed\n")

    assert {:error, {:orphaned_from_failed_create, ^target}} = Create.claim_target(root, target)
    assert File.exists?(target)
  end

  test "a create cut off before its worktree existed leaves only markers, which are cleared",
       %{root: root, target: target} do
    git!(root, ["worktree", "remove", "--force", target])
    File.mkdir_p!(target)
    File.write!(Path.join(target, ".cms_harness_preparing"), "preparing\n")

    assert :ok = Create.claim_target(root, target)
    refute File.exists?(target)
  end

  test "markers beside anything else are refused", %{root: root, target: target} do
    git!(root, ["worktree", "remove", "--force", target])
    File.mkdir_p!(target)
    File.write!(Path.join(target, ".cms_harness.json"), "{}\n")
    File.write!(Path.join(target, "notes.txt"), "mine\n")

    assert {:error, {:orphaned_from_failed_create, ^target}} = Create.claim_target(root, target)
  end

  test "a directory with no identity marker still refuses as a bare already_exists", %{
    root: root,
    target: target
  } do
    File.rm_rf!(target)
    File.mkdir_p!(target)
    File.write!(Path.join(target, "somebody_elses_file"), "not ours\n")

    assert {:error, {:already_exists, ^target}} =
             Create.run(root, %{"label" => "x", "root" => target})
  end
end
