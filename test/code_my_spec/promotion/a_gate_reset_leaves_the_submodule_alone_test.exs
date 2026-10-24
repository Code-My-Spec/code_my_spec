defmodule CodeMySpec.Promotion.AGateResetLeavesTheSubmoduleAloneTest do
  @moduledoc """
  `Steps.build_batch/4` resetting the gate checkout to a commit whose
  `.code_my_spec` pointer the checkout's submodule does not have.

  0dab340e, 2026-10-05: the repository sets `submodule.recurse`, so resetting
  the gate copy back to a batch commit tried to check that pointer out, could
  not ("failed to unpack tree object"), and the batch was rebuilt and reset
  again, every few minutes. The queue's resets leave the submodule where it is,
  as building the batch by merges always has.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.Promotion.Steps

  setup do
    origin = CodeMySpec.TempFile.owned_dir("test")
    seed = CodeMySpec.TempFile.owned_dir("test")
    root = CodeMySpec.TempFile.owned_dir("test")

    {_, 0} = git(origin, ["init", "-q", "--bare", "--initial-branch=main"])
    {_, 0} = git(seed, ["init", "-q", "--initial-branch=main"])
    commit(seed, "one")
    {_, 0} = git(seed, ["push", "-q", origin, "main"])

    {_, 0} = git(root, ["init", "-q", "--initial-branch=main"])
    File.write!(Path.join(root, "app.ex"), "defmodule App do\nend\n")
    {_, 0} = git(root, ["add", "app.ex"])
    commit(root, "app")

    {_, 0} =
      git(root, [
        "-c",
        "protocol.file.allow=always",
        "submodule",
        "add",
        "-q",
        origin,
        ".code_my_spec"
      ])

    main = commit(root, "add docs")
    {_, 0} = git(root, ["config", "submodule.recurse", "true"])

    # A batch commit pinning a docs commit this checkout's submodule never had.
    missing = String.duplicate("a", 40)
    {_, 0} = git(root, ["update-index", "--cacheinfo", "160000,#{missing},.code_my_spec"])
    pinned = commit(root, "pin a docs commit that is not here")
    {_, 0} = git(root, ["-c", "submodule.recurse=false", "checkout", "-q", "--detach", main])

    %{root: root, main: main, pinned: pinned, env: ExecutionContext.new(:local, root)}
  end

  test "the gate checkout is reset to a commit pinning a docs commit it does not have", ctx do
    assert {:ok, %{head: pinned}} = Steps.build_batch(ctx.env, ctx.root, ctx.pinned, [])
    assert pinned == ctx.pinned

    assert {:ok, %{head: main}} = Steps.build_batch(ctx.env, ctx.root, ctx.main, [])
    assert main == ctx.main
  end

  defp git(dir, args), do: System.cmd("git", args, cd: dir, stderr_to_stdout: true)

  defp commit(dir, message) do
    {_, 0} =
      git(dir, [
        "-c",
        "user.email=t@example.com",
        "-c",
        "user.name=T",
        "commit",
        "-q",
        "--allow-empty",
        "-m",
        message
      ])

    {sha, 0} = git(dir, ["rev-parse", "HEAD"])
    String.trim(sha)
  end
end
