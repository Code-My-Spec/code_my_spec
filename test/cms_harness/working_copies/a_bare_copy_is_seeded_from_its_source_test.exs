defmodule CmsHarness.WorkingCopies.ABareCopyIsSeededFromItsSourceTest do
  # dfddf29c, 30c655fc: a bare `git worktree add` copy had no deps/ and no
  # untracked dotenvs, and every failure there read as a code defect.
  use ExUnit.Case, async: true

  alias CmsHarness.WorkingCopies.Create

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    target = Path.join(dir, "target")
    File.mkdir_p!(Path.join([source, "deps", "boundary", ".git"]))
    File.write!(Path.join([source, "deps", "boundary", "mix.exs"]), "boundary\n")
    File.write!(Path.join([source, "deps", "boundary", ".git", "HEAD"]), "ae2560a8\n")
    File.mkdir_p!(target)
    %{source: source, target: target}
  end

  test "deps/ is copied, not linked, with the git deps' own history", ctx do
    assert :ok = Create.seed(ctx.source, ctx.target)

    deps = Path.join(ctx.target, "deps")
    assert {:ok, %{type: :directory}} = File.lstat(deps)
    assert File.read!(Path.join([deps, "boundary", ".git", "HEAD"])) == "ae2560a8\n"
  end

  test "deps/ the copy already has is left alone", ctx do
    File.mkdir_p!(Path.join(ctx.target, "deps"))

    assert :ok = Create.seed(ctx.source, ctx.target)
    refute File.exists?(Path.join([ctx.target, "deps", "boundary"]))
  end

  test "untracked dotenvs are linked to the source's; committed ones are kept", ctx do
    File.write!(Path.join(ctx.source, ".env.test"), "GOOGLE_CLIENT_ID=x\n")
    File.write!(Path.join(ctx.source, ".env.example"), "source\n")
    File.write!(Path.join(ctx.target, ".env.example"), "committed\n")

    assert :ok = Create.seed(ctx.source, ctx.target)

    linked = Path.join(ctx.target, ".env.test")
    assert {:ok, %{type: :symlink}} = File.lstat(linked)
    assert File.read!(linked) == "GOOGLE_CLIENT_ID=x\n"
    assert File.read!(Path.join(ctx.target, ".env.example")) == "committed\n"
  end
end
