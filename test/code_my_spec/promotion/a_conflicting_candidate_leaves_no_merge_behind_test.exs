defmodule CodeMySpec.Promotion.AConflictingCandidateLeavesNoMergeBehindTest do
  @moduledoc """
  2026-10-15: candidate 8733d80d8 conflicted with main in a file and in the
  `.code_my_spec` pointer. `git merge --abort` failed under `submodule.recurse`,
  so the gate kept the half-merge and the next step compiled its conflict
  markers: the batch failed as "could not reset the gate's test database"
  instead of ejecting the one candidate as a conflict.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
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
    write(root, "line\n")

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

    base = commit(root, "base")
    {_, 0} = git(root, ["config", "submodule.recurse", "true"])

    candidate = diverge(root, base, "candidate\n", String.duplicate("a", 40))
    main = diverge(root, base, "main\n", String.duplicate("b", 40))

    %{root: root, main: main, candidate: candidate, env: Environment.new(:local, root)}
  end

  test "a candidate conflicting in a file and the docs pointer leaves a clean tree", ctx do
    assert {:ok, %{merged: [], conflicted: [%{commit: commit}]}} =
             Steps.build_batch(ctx.env, ctx.root, ctx.main, [ctx.candidate])

    assert commit == ctx.candidate
    refute File.read!(Path.join(ctx.root, "app.ex")) =~ "<<<<<<<"
    {merge_head, _} = git(ctx.root, ["rev-parse", "-q", "--verify", "MERGE_HEAD"])
    assert merge_head == ""
  end

  # One commit off `base` that rewrites app.ex and pins a docs commit the
  # submodule never had.
  defp diverge(root, base, content, pointer) do
    {_, 0} = git(root, ["-c", "submodule.recurse=false", "checkout", "-q", "--detach", base])
    write(root, content)
    {_, 0} = git(root, ["update-index", "--cacheinfo", "160000,#{pointer},.code_my_spec"])
    commit(root, content)
  end

  defp write(root, content) do
    File.write!(Path.join(root, "app.ex"), content)
    {_, 0} = git(root, ["add", "app.ex"])
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
