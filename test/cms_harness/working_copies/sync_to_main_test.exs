defmodule CmsHarnessTest.WorkingCopies.SyncToMainTest do
  @moduledoc """
  8f5ebfb2: nothing reachable could bring a stale working copy's checkout up
  to date before staffing it. These exercise the git mechanics directly,
  against real repositories, rather than the channel round trip -- the
  round trip is `apply_fs/3`'s one-line dispatch to this module, already
  exercised the same way every other `fs_request` op is.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.WorkingCopies.SyncToMain

  setup do
    origin = CodeMySpec.TempFile.owned_dir("sync_to_main_origin")
    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", origin])

    clone = CodeMySpec.TempFile.owned_dir("sync_to_main_clone")

    {_, 0} =
      System.cmd("git", ["clone", origin, clone], stderr_to_stdout: true)

    commit!(clone, "README.md", "first\n", "root")
    {_, 0} = git(clone, ["push", "origin", "main"])

    %{origin: origin, clone: clone}
  end

  test "already at main's HEAD reports no update", %{clone: clone} do
    assert {:ok, %{from: sha, to: sha, updated: false}} = SyncToMain.run(clone, %{})
  end

  test "a new commit on the remote is fast-forwarded in", %{origin: origin, clone: clone} do
    before = head(clone)

    other_clone = CodeMySpec.TempFile.owned_dir("sync_to_main_other_clone")
    {_, 0} = System.cmd("git", ["clone", origin, other_clone], stderr_to_stdout: true)
    commit!(other_clone, "second.md", "second\n", "second")
    {_, 0} = git(other_clone, ["push", "origin", "main"])

    assert {:ok, %{from: ^before, to: after_sha, updated: true}} = SyncToMain.run(clone, %{})
    assert after_sha == head(other_clone)

    assert File.exists?(Path.join(clone, "second.md")),
           "the fast-forward did not update the working tree"
  end

  test "an uncommitted change refuses rather than merging into it", %{
    origin: origin,
    clone: clone
  } do
    other_clone = CodeMySpec.TempFile.owned_dir("sync_to_main_other_clone")
    {_, 0} = System.cmd("git", ["clone", origin, other_clone], stderr_to_stdout: true)
    commit!(other_clone, "second.md", "second\n", "second")
    {_, 0} = git(other_clone, ["push", "origin", "main"])

    File.write!(Path.join(clone, "README.md"), "uncommitted change\n")

    assert {:error, %{tag: :dirty_tree}} = SyncToMain.run(clone, %{})

    assert File.read!(Path.join(clone, "README.md")) == "uncommitted change\n",
           "the refusal must not have touched the dirty file"
  end

  test "diverged history refuses rather than making a merge commit", %{
    origin: origin,
    clone: clone
  } do
    # The remote moves...
    other_clone = CodeMySpec.TempFile.owned_dir("sync_to_main_other_clone")
    {_, 0} = System.cmd("git", ["clone", origin, other_clone], stderr_to_stdout: true)
    commit!(other_clone, "second.md", "second\n", "second")
    {_, 0} = git(other_clone, ["push", "origin", "main"])

    # ...and so does this checkout, independently, without ever pushing.
    commit!(clone, "local-only.md", "local\n", "local-only")
    before = head(clone)

    assert {:error, %{tag: :not_fast_forward}} = SyncToMain.run(clone, %{})
    assert head(clone) == before, "a refused merge must leave HEAD exactly where it was"
  end

  test "remote and branch are overridable", %{origin: _origin, clone: clone} do
    {_, 0} = git(clone, ["remote", "rename", "origin", "upstream"])

    assert {:ok, %{updated: false}} = SyncToMain.run(clone, %{"remote" => "upstream"})
  end

  defp commit!(root, file, content, message) do
    File.write!(Path.join(root, file), content)
    {_, 0} = git(root, ["add", "."])

    {_, 0} =
      git(root, [
        "-c",
        "user.email=spex@example.com",
        "-c",
        "user.name=Spex",
        "commit",
        "-m",
        message
      ])
  end

  defp head(root) do
    {sha, 0} = git(root, ["rev-parse", "HEAD"])
    String.trim(sha)
  end

  defp git(root, args), do: System.cmd("git", ["-C", root] ++ args, stderr_to_stdout: true)
end
