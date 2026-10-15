defmodule CodeMySpec.WorkingCopies.ALostIdentityMintsFreshTest do
  @moduledoc """
  A join with no id is always a new agent, even from a path and device the
  server has seen -- story 1000's criterion 5.

  `recognise_or_create/3` used to look a checkout up by `(project_id,
  device_id, root)` before minting, specifically to collapse the churn a
  harness produces when it cannot read its own `.cms_harness.json` (measured
  at the time: 52 rows for one worktree, five within a single second). That
  silently merged two different agents sharing one path on one machine --
  exactly story 733's trap, and exactly what criterion 5 forbids. 45c044d1.

  ## What this reopens

  The churn the lookup existed to stop is back: a harness that repeatedly
  fails to persist its id mints a row every time it rejoins. Reclaiming those
  quiet duplicates is its own piece of work, not this one -- see 45c044d1.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.WorkingCopies

  @root "/workspace/app"

  defp device(scope, hostname) do
    {:ok, device} = Devices.announce(scope, nil, %{hostname: hostname, kind: :local})
    device
  end

  test "a checkout that rejoins without its id mints a fresh identity, not the one it lost" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")

    {:ok, first} =
      WorkingCopies.issue(scope, nil, label: "first join", device: laptop, root: @root)

    {:ok, first} = WorkingCopies.report_root(first, @root)

    # The same checkout joins again having lost its config file -- what every
    # one of the 52 duplicates was, and exactly criterion 733's trap: nothing
    # at the protocol level tells this apart from a second agent at the same
    # path on the same machine.
    {:ok, again} =
      WorkingCopies.issue(scope, nil, label: "second join", device: laptop, root: @root)

    {:ok, again} = WorkingCopies.report_root(again, @root)

    refute again.id == first.id,
           "a checkout presenting no id was recognised by its device and root and handed " <>
             "the previous agent's identity -- two agents at one path are two agents " <>
             "(criterion 733), so this would hand a stranger somebody else's files."

    ids = Enum.map(WorkingCopies.list_harnesses(scope), & &1.id)

    assert first.id in ids and again.id in ids,
           "both rows must exist as their own checkouts, not one overwriting the other"
  end

  test "the first copy's identity and root are untouched by a second mint at its path" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")

    {:ok, first} =
      WorkingCopies.issue(scope, nil, label: "first join", device: laptop, root: @root)

    {:ok, first} = WorkingCopies.report_root(first, @root)

    {:ok, again} =
      WorkingCopies.issue(scope, nil, label: "second join", device: laptop, root: @root)

    {:ok, _again} = WorkingCopies.report_root(again, @root)

    assert {:ok, reloaded} = WorkingCopies.fetch(first.id)

    assert reloaded.id == first.id
    assert reloaded.root == @root
    assert reloaded.label == "first join",
           "a second checkout minting at this path must not rewrite what the first one " <>
             "already recorded about itself"
  end

  test "two machines at the same path stay two working copies" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")
    sprite = device(scope, "a-sprite")

    {:ok, on_laptop} = WorkingCopies.issue(scope, nil, device: laptop, root: @root)
    {:ok, _on_laptop} = WorkingCopies.report_root(on_laptop, @root)

    {:ok, on_sprite} = WorkingCopies.issue(scope, nil, device: sprite, root: @root)
    {:ok, _on_sprite} = WorkingCopies.report_root(on_sprite, @root)

    refute on_sprite.id == on_laptop.id,
           "two machines were merged into one working copy because they share a path. " <>
             "Every container sits at /workspace/app; the device is the only thing that " <>
             "tells them apart, which is what criterion 2843 is about."
  end

  test "a join carrying no device still mints, rather than guessing" do
    scope = full_scope_fixture()

    {:ok, first} =
      WorkingCopies.issue(scope, nil, root: @root, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    {:ok, _} = WorkingCopies.report_root(first, @root)

    {:ok, second} =
      WorkingCopies.issue(scope, nil, root: @root, device: CodeMySpec.DevicesFixtures.device_fixture(scope))

    refute second.id == first.id
  end

  test "an id that is recognised is still what wins" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")

    {:ok, first} = WorkingCopies.issue(scope, nil, device: laptop, root: @root)
    {:ok, first} = WorkingCopies.report_root(first, @root)

    {:ok, presented} =
      WorkingCopies.issue(scope, first.id, device: laptop, root: "/somewhere/else")

    assert presented.id == first.id,
           "a checkout presenting an id it was issued has to be recognised by it -- " <>
             "the id is the identity and the root is a report about where it sits"
  end

  describe "the database allows what the join now does" do
    test "a second row for one directory on one machine succeeds, not refused" do
      scope = full_scope_fixture()
      laptop = device(scope, "a-laptop")

      {:ok, first} = WorkingCopies.issue(scope, nil, device: laptop, root: @root)
      {:ok, _} = WorkingCopies.report_root(first, @root)

      {:ok, second} =
        WorkingCopies.issue(scope, nil, label: "second mint", device: laptop, root: @root)

      assert {:ok, _} = WorkingCopies.report_root(second, @root),
             "the unique index that used to backstop recognise_or_create/3 has to be gone " <>
               "along with it -- a join with no id must succeed at minting AND at " <>
               "reporting its root, or criterion 5's 'the server issues a new identity' " <>
               "is not actually true"
    end
  end
end
