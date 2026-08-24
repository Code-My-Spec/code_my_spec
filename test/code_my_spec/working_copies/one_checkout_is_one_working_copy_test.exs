defmodule CodeMySpec.WorkingCopies.OneCheckoutIsOneWorkingCopyTest do
  @moduledoc """
  A directory on a machine is one working copy, however many times it rejoins.

  `issue/3` minted whenever the presented id was not recognised, and nothing
  looked at where the checkout was. A harness that could not read its own
  `.cms_harness.json` therefore became a new working copy on every join.

  Measured on this project before the fix: **178 working copy rows for 100
  distinct roots** — 52 for one worktree, five of those minted inside a single
  second, and only one of the 52 carrying any files. Everything keyed on the
  working copy then splits across identities describing the same directory:
  files under one, problems under another, requirement verdicts under a third.

  ## Why not root alone

  Because two machines share a path constantly — every container at
  `/workspace/app` — which is why `root` is recorded as reported rather than
  identifying, and why story 1020's criterion 2843 exists at all. That criterion
  also settled what disambiguates them: the device. This uses both, and only
  both.
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

  test "a checkout that rejoins without its id is recognised, not minted again" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")

    {:ok, first} =
      WorkingCopies.issue(scope, nil, label: "first join", device: laptop, root: @root)

    {:ok, first} = WorkingCopies.report_root(first, @root)
    {:ok, first} = Devices.attach(first, laptop)

    # The same checkout joins again having lost its config file — which is what
    # every one of the 52 duplicates was.
    {:ok, again} =
      WorkingCopies.issue(scope, nil, label: "second join", device: laptop, root: @root)

    assert again.id == first.id,
           "the same directory on the same machine was issued a second identity. " <>
             "Everything keyed on the working copy — files, problems, requirement " <>
             "verdicts — then splits across two rows describing one checkout."
  end

  test "two machines at the same path stay two working copies" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")
    sprite = device(scope, "a-sprite")

    {:ok, on_laptop} = WorkingCopies.issue(scope, nil, device: laptop, root: @root)
    {:ok, on_laptop} = WorkingCopies.report_root(on_laptop, @root)
    {:ok, _} = Devices.attach(on_laptop, laptop)

    {:ok, on_sprite} = WorkingCopies.issue(scope, nil, device: sprite, root: @root)

    refute on_sprite.id == on_laptop.id,
           "two machines were merged into one working copy because they share a " <>
             "path. Every container sits at /workspace/app; the device is the only " <>
             "thing that tells them apart, which is what criterion 2843 is about."
  end

  test "a join carrying no device still mints, rather than guessing" do
    scope = full_scope_fixture()

    {:ok, first} = WorkingCopies.issue(scope, nil, root: @root)
    {:ok, _} = WorkingCopies.report_root(first, @root)

    {:ok, second} = WorkingCopies.issue(scope, nil, root: @root)

    refute second.id == first.id,
           "without a device this cannot tell two machines apart, and merging on " <>
             "root alone would fold somebody else's checkout into this one. A " <>
             "harness too old to say which machine it is on gets the pre-device " <>
             "behaviour."
  end

  test "an id that is recognised is still what wins" do
    scope = full_scope_fixture()
    laptop = device(scope, "a-laptop")

    {:ok, first} = WorkingCopies.issue(scope, nil, device: laptop, root: @root)
    {:ok, first} = WorkingCopies.report_root(first, @root)
    {:ok, _} = Devices.attach(first, laptop)

    {:ok, presented} =
      WorkingCopies.issue(scope, first.id, device: laptop, root: "/somewhere/else")

    assert presented.id == first.id,
           "a checkout presenting an id it was issued has to be recognised by it — " <>
             "the id is the identity and the root is a report about where it sits"
  end
end
