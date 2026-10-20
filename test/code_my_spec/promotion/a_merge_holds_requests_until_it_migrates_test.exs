defmodule CodeMySpec.Promotion.AMergeHoldsRequestsUntilItMigratesTest do
  @moduledoc """
  Issue 725a1d32: `Steps.merge` puts the app serving the checkout on hold for the
  gap between the merge and its migrations (`CodeMySpecWeb.Plugs.HoldDuringLanding`),
  and takes the hold down itself when no reload or restart is coming to.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Steps

  defp repo do
    root = CodeMySpec.TempFile.owned_dir("hold")
    git = fn args -> System.cmd("git", args, cd: root, stderr_to_stdout: true) end

    {_, 0} = git.(["init", "--initial-branch=main"])
    {_, 0} = git.(["config", "user.email", "t@example.com"])
    {_, 0} = git.(["config", "user.name", "T"])
    File.write!(Path.join(root, "f.txt"), "base\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "base"])
    {root, git}
  end

  defp hold(root), do: Path.join(root, ".git/landing_hold")

  test "a merge that moves code leaves the hold for the reload to take down" do
    {root, git} = repo()
    {_, 0} = git.(["checkout", "-b", "side"])
    File.write!(Path.join(root, "g.txt"), "new\n")
    {_, 0} = git.(["add", "."])
    {_, 0} = git.(["commit", "-m", "side"])
    {_, 0} = git.(["checkout", "main"])

    assert {:ok, %{changed: [_ | _]}} = Steps.merge(Environment.new(:local, root), root, "side")

    assert File.exists?(hold(root))
    assert hold(root) |> File.read!() |> String.trim() |> String.to_integer() > 0

    {status, 0} = git.(["status", "--porcelain"])
    assert status == "", "the hold lives in .git so it never dirties the tree: #{status}"
  end

  test "a merge that moves nothing takes the hold down itself" do
    {root, _git} = repo()

    assert {:ok, _} = Steps.merge(Environment.new(:local, root), root, "main")

    refute File.exists?(hold(root))
  end

  test "a refused merge takes the hold down itself" do
    {root, _git} = repo()

    assert {:error, _} = Steps.merge(Environment.new(:local, root), root, "no-such-branch")

    refute File.exists?(hold(root))
  end
end
