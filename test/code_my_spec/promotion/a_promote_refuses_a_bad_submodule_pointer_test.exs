defmodule CodeMySpec.Promotion.APromoteRefusesABadSubmodulePointerTest do
  @moduledoc """
  7e7539ec: a promote accepted a branch that moved main's `.code_my_spec`
  gitlink backwards (a stale submodule checkout committed with the work), and
  another that pinned a docs commit never pushed to the docs remote. The
  precheck now refuses both, checked against the submodule's `origin` — here a
  local bare repo, so nothing touches the network.
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
    first = commit(seed, "one")
    second = commit(seed, "two")
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
    {_, 0} = git(root, ["checkout", "-q", "-b", "story"])

    %{
      root: root,
      sub: Path.join(root, ".code_my_spec"),
      origin: origin,
      main: main,
      first: first,
      second: second,
      env: Environment.new(:local, root)
    }
  end

  test "a branch that leaves the pointer alone passes without reaching the remote", ctx do
    File.write!(Path.join(ctx.root, "app.ex"), "defmodule App do\n  def x, do: 1\nend\n")
    {_, 0} = git(ctx.root, ["add", "app.ex"])
    commit(ctx.root, "work")
    unreachable(ctx.sub, ctx.origin)

    assert {:ok, %{branch: "story"}} = Steps.precheck(ctx.env, ctx.root, ctx.main)
  end

  test "a pointer that descends from main's and is on the remote passes", ctx do
    commit(ctx.sub, "three")
    {_, 0} = git(ctx.sub, ["push", "-q", "origin", "HEAD:main"])
    pin(ctx.root)

    assert {:ok, %{branch: "story"}} = Steps.precheck(ctx.env, ctx.root, ctx.main)
  end

  test "a pointer moved back to an ancestor of main's is refused, naming both", ctx do
    {_, 0} = git(ctx.sub, ["checkout", "-q", ctx.first])
    pin(ctx.root)

    assert {:error, %{reason: reason, submodule: submodule}} =
             Steps.precheck(ctx.env, ctx.root, ctx.main)

    assert submodule == %{main: ctx.second, branch: ctx.first}
    assert reason =~ "from #{ctx.second} back to #{ctx.first}"
    assert reason =~ "git update-index --cacheinfo 160000,#{ctx.second},.code_my_spec"
  end

  test "a pointer that diverged from main's is refused, even when pushed", ctx do
    {_, 0} = git(ctx.sub, ["checkout", "-q", ctx.first])
    diverged = commit(ctx.sub, "sideways")
    {_, 0} = git(ctx.sub, ["push", "-q", "origin", "HEAD:refs/heads/sideways"])
    pin(ctx.root)

    assert {:error, %{reason: reason, submodule: %{main: main_ptr, branch: ^diverged}}} =
             Steps.precheck(ctx.env, ctx.root, ctx.main)

    assert main_ptr == ctx.second
    assert reason =~ "from #{ctx.second} to #{diverged}"
    assert reason =~ "diverged"
  end

  test "a pointer that was never pushed to the docs remote is refused", ctx do
    unpushed = commit(ctx.sub, "local only")
    pin(ctx.root)

    assert {:error, %{reason: reason}} = Steps.precheck(ctx.env, ctx.root, ctx.main)

    assert reason =~ "from #{ctx.second} to #{unpushed}"
    assert reason =~ "not on any branch of the docs remote (#{ctx.origin})"
    assert reason =~ "Push #{unpushed} to the docs remote first"
  end

  test "a remote that cannot be reached refuses rather than passing", ctx do
    commit(ctx.sub, "three")
    {_, 0} = git(ctx.sub, ["push", "-q", "origin", "HEAD:main"])
    pin(ctx.root)
    unreachable(ctx.sub, ctx.origin)

    assert {:error, %{reason: reason}} = Steps.precheck(ctx.env, ctx.root, ctx.main)

    assert reason =~ "could not fetch .code_my_spec's origin"
    assert reason =~ "Nothing was merged"
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

  defp pin(root) do
    {_, 0} = git(root, ["add", ".code_my_spec"])
    commit(root, "move docs pointer")
  end

  defp unreachable(sub, origin) do
    {_, 0} = git(sub, ["remote", "set-url", "origin", Path.join(origin, "gone")])
  end
end
