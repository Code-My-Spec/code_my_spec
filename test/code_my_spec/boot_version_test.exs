defmodule CodeMySpec.BootVersionTest do
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

  # Sync: `:persistent_term` is node-global, so the cached boot version one test
  # writes is the one every other test reads.
  use ExUnit.Case, async: false

  alias CodeMySpec.BootVersion

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

  # A checkout with an upstream, and a second one able to push to it. That is
  # the worktree situation in miniature: code arrives on the upstream ref
  # without this checkout's HEAD ever moving.
  defp origin_and_clone do
    {:ok, origin} = Briefly.create(directory: true)
    # `--initial-branch=main` so a clone lands on main. Without it the bare repo
    # HEAD is an unborn default, and a second clone commits onto an unrelated
    # branch whose push is refused as non-fast-forward.
    {_, 0} = System.cmd("git", ["init", "--quiet", "--bare", "--initial-branch=main"], cd: origin)

    work = clone(origin)
    commit(work, "one")
    {_, 0} = System.cmd("git", ["push", "-q", "-u", "origin", "HEAD:main"], cd: work)

    {origin, work}
  end

  defp clone(origin) do
    {:ok, dir} = Briefly.create(directory: true)
    root = Path.join(dir, "checkout")
    {_, 0} = System.cmd("git", ["clone", "-q", origin, root], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "t@example.com"], cd: root)
    {_, 0} = System.cmd("git", ["config", "user.name", "t"], cd: root)
    root
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

  # `drift/0` answers "has the checkout moved since boot", which is a different
  # question from "which code is this". A server behind main is not drifting —
  # its own checkout has not moved — and yet it is exactly the case an agent
  # needs named, because a stale message about correctness reads as the fix not
  # working rather than as the build being old (5e59a29d).
  describe "booted/0" do
    test "reports the recorded commit" do
      BootVersion.capture(File.cwd!())

      assert is_binary(BootVersion.booted())
      assert String.length(BootVersion.booted()) >= 7
    end

    # The short form, which is what `head/1` records — asserted against git
    # rather than against a length, so the two cannot drift apart silently.
    test "it is the commit HEAD names" do
      BootVersion.capture(File.cwd!())

      {head, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: File.cwd!())

      assert BootVersion.booted() == String.trim(head)
    end
  end

  # A packaged server has no checkout of its own, and `capture/1` must not run
  # there: it defaults to `File.cwd!()`, which for a released binary is wherever
  # the user invoked it — usually *a* project, whose HEAD says nothing about the
  # code running. A confidently wrong sha is worse than no sha, so the fallback
  # is the release version, which `just publish` moves with the build.
  describe "describe/0" do
    test "is the commit when one was captured" do
      BootVersion.capture(File.cwd!())

      assert BootVersion.describe() == BootVersion.booted()
    end

    test "falls back to the release version when nothing was captured" do
      BootVersion.capture("/nonexistent-so-nothing-is-recorded")

      assert BootVersion.describe() == "v#{Application.spec(:code_my_spec, :vsn)}"
    end

    test "always answers something, so a caller never has to branch" do
      BootVersion.capture("/nonexistent-so-nothing-is-recorded")

      refute BootVersion.describe() == ""
      assert is_binary(BootVersion.describe())
    end
  end

  # 9c474a9d. The harness and server run from the main checkout; an agent in a
  # worktree pushes to origin/main and that checkout's HEAD never moves. The old
  # comparison found booted == HEAD and said nothing, while five commits sat
  # unrun — two of them touching the channel contract, which is precisely what
  # `contract_changed?/2` exists to notice.
  #
  # A local read: worktrees share refs, so the push updates the remote-tracking
  # ref without a fetch. The clone here needs one to reach the same state.
  describe "code that arrived without the checkout moving" do
    test "a checkout behind its upstream is drifted, though its HEAD has not moved" do
      {origin, work} = origin_and_clone()

      BootVersion.capture(work)
      head_at_boot = head_of(work)

      other = clone(origin)
      commit(other, "two")
      {_, 0} = System.cmd("git", ["push", "-q", "origin", "HEAD:main"], cd: other, stderr_to_stdout: true)
      {_, 0} = System.cmd("git", ["fetch", "-q"], cd: work)

      assert head_of(work) == head_at_boot,
             "the premise of this test is that HEAD did not move"

      assert {:drifted, booted, current} = BootVersion.drift()
      assert booted == head_at_boot
      assert booted != current
    end

    # A checkout ahead of its upstream is running the newest code there is.
    # Reporting that as drift would fire on every commit before it is pushed,
    # which is most of an active session, and a warning that is always on is one
    # nobody reads.
    test "a checkout ahead of its upstream is not drifted" do
      {_origin, work} = origin_and_clone()

      BootVersion.capture(work)
      commit(work, "local work")

      # Moved HEAD, so the *first* rule fires. What must not happen is a report
      # naming the upstream as what it should be running.
      assert {:drifted, _booted, current} = BootVersion.drift()
      assert current == head_of(work)
    end

    test "a checkout with no upstream at all is not drifted" do
      root = git_repo()
      commit(root, "one")

      BootVersion.capture(root)

      assert BootVersion.drift() == :none
    end
  end

  defp head_of(root) do
    {output, 0} = System.cmd("git", ["rev-parse", "--short", "HEAD"], cd: root)
    String.trim(output)
  end
end
