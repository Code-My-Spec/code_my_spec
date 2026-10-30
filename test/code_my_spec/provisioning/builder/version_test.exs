defmodule CodeMySpec.Provisioning.Builder.VersionTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Builder.Version

  setup do
    repo = CodeMySpec.TempFile.dir("cms-builder-version")
    File.mkdir_p!(repo)
    git = fn args -> System.cmd("git", args, cd: repo, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "-q", "-b", "main"])
    {_, 0} = git.(["config", "user.email", "builder@example.com"])
    {_, 0} = git.(["config", "user.name", "Builder"])
    File.write!(Path.join(repo, "source"), "first")
    {_, 0} = git.(["add", "source"])
    {_, 0} = git.(["commit", "-q", "-m", "first"])
    {first, 0} = git.(["rev-parse", "HEAD"])
    first = String.trim(first)
    {_, 0} = git.(["tag", "v2.4.6", first])

    File.write!(Path.join(repo, "source"), "second")
    {_, 0} = git.(["commit", "-q", "-am", "second"])
    {second, 0} = git.(["rev-parse", "HEAD"])

    on_exit(fn -> File.rm_rf(repo) end)
    %{repo: repo, first: first, second: String.trim(second)}
  end

  test "uses the release tag on the requested commit even after HEAD moves", ctx do
    assert {:ok, "v2.4.6"} = Version.for_ref(String.slice(ctx.first, 0, 12), version_cd: ctx.repo)
  end

  test "uses the requested untagged commit's short SHA", ctx do
    assert {:ok, String.slice(ctx.second, 0, 12)} ==
             Version.for_ref(String.slice(ctx.second, 0, 12), version_cd: ctx.repo)
  end

  test "refuses an unknown commit with a plain message", ctx do
    assert {:error, "cannot build image: could not determine the commit being built"} =
             Version.for_ref("000000000000", version_cd: ctx.repo)
  end
end
