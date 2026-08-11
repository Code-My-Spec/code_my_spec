defmodule CmsHarness.BootVersionTest do
  @moduledoc """
  A harness that has outlived its checkout can say so.

  From `7e8fd1c6`: 137 commits merged mid-session moved the harness↔server
  channel contract, and every stop afterwards failed with
  `{:error, %{"reason" => "unmatched topic"}}` — an error naming neither the
  merge nor the harness. Restarting the harness fixed it. The suggestion was to
  compare the SHA it booted from against the checkout's HEAD and say so plainly.

  The assertions that matter are the silences. Drift is the normal state of an
  active session, so this is consulted only beside an error the reader is
  already holding — and every uncertain case answers `:none`, because an
  uncertain answer appended to an error message reads as evidence, and a wrong
  "restart your harness" costs more than a missing one.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.BootVersion

  setup do
    on_exit(fn -> :persistent_term.erase({BootVersion, :boot}) end)
    :ok
  end

  defp git_repo do
    {:ok, root} = Briefly.create(directory: true)
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: root, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: root)
    root
  end

  defp commit(root, message) do
    File.write!(Path.join(root, "#{System.unique_integer([:positive])}.txt"), message)
    {_, 0} = System.cmd("git", ["add", "-A"], cd: root, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["commit", "-qm", message], cd: root, stderr_to_stdout: true)
    :ok
  end

  test "a checkout that has not moved reports no drift" do
    root = git_repo()
    commit(root, "one")

    BootVersion.capture(root)

    assert BootVersion.drift() == :none
  end

  test "a checkout that has moved names both commits" do
    root = git_repo()
    commit(root, "one")

    BootVersion.capture(root)
    commit(root, "two")

    assert {:drifted, booted, current} = BootVersion.drift()
    assert booted != current
    assert String.length(booted) >= 7
  end

  describe "cases that must stay silent" do
    test "never captured" do
      assert BootVersion.drift() == :none
    end

    test "a directory that is not a git checkout" do
      {:ok, root} = Briefly.create(directory: true)

      BootVersion.capture(root)

      assert BootVersion.drift() == :none,
             "a sprite runs from an unpacked release with no checkout; that is " <>
               "not drift and must not be reported as it"
    end

    test "a root that has since gone away" do
      root = git_repo()
      commit(root, "one")
      BootVersion.capture(root)
      File.rm_rf!(root)

      assert BootVersion.drift() == :none,
             "a `:cd` into a missing directory raises; this decorates an error " <>
               "path and must not be able to take it down"
    end
  end
end
