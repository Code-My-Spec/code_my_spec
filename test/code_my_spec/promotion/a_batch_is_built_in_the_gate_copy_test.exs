defmodule CodeMySpec.Promotion.ABatchIsBuiltInTheGateCopyTest do
  @moduledoc """
  `Steps.build_batch/4`: the gate checkout is reset to main and the queue's
  candidates are merged onto it in order — a fast-forward when one is level
  with what is already there, a merge commit otherwise, and a conflict aborted
  and reported rather than left in the tree.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Steps

  setup do
    root = CodeMySpec.TempFile.owned_dir("test")
    git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end
    {_, 0} = git.(["init", "--initial-branch=main"])
    {_, 0} = git.(["config", "user.email", "t@example.com"])
    {_, 0} = git.(["config", "user.name", "T"])
    File.write!(Path.join(root, "app.ex"), "base\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "base"])

    gate = CodeMySpec.TempFile.owned_dir("test")
    File.rm_rf!(gate)
    {_, 0} = git.(["worktree", "add", "--detach", gate, "main"])

    head = fn -> git.(["rev-parse", "HEAD"]) |> elem(0) |> String.trim() end

    branch = fn name, from, file, content ->
      {_, 0} = git.(["checkout", "-q", "-b", name, from])
      File.write!(Path.join(root, file), content)
      {_, 0} = git.(["add", file])
      {_, 0} = git.(["commit", "-q", "-m", name])
      sha = head.()
      {_, 0} = git.(["checkout", "-q", "main"])
      sha
    end

    main = head.()
    %{root: root, gate: gate, main: main, branch: branch, env: Environment.new(:local, gate)}
  end

  test "a lone candidate level with main is the batch commit itself", ctx do
    a = ctx.branch.("a", "main", "a.ex", "a\n")

    assert {:ok, %{head: ^a, merged: [^a], conflicted: []}} =
             Steps.build_batch(ctx.env, ctx.gate, ctx.main, [a])
  end

  test "a stacked candidate fast-forwards; a sibling is merged", ctx do
    a = ctx.branch.("a", "main", "a.ex", "a\n")
    b = ctx.branch.("b", "a", "b.ex", "b\n")
    c = ctx.branch.("c", "main", "c.ex", "c\n")

    assert {:ok, %{head: head, merged: [^a, ^b, ^c], conflicted: []}} =
             Steps.build_batch(ctx.env, ctx.gate, ctx.main, [a, b, c])

    {parents, 0} = System.cmd("git", ["rev-list", "--parents", "-n", "1", head], cd: ctx.gate)
    assert parents |> String.split() |> tl() |> Enum.sort() == Enum.sort([b, c])
  end

  test "a candidate that conflicts is left out and named, and the tree is clean", ctx do
    a = ctx.branch.("a", "main", "app.ex", "a's version\n")
    b = ctx.branch.("b", "main", "app.ex", "b's version\n")

    assert {:ok, %{head: ^a, merged: [^a], conflicted: [%{commit: ^b, files: ["app.ex"]}]}} =
             Steps.build_batch(ctx.env, ctx.gate, ctx.main, [a, b])

    assert {"", 0} = System.cmd("git", ["status", "--porcelain"], cd: ctx.gate)
  end
end
