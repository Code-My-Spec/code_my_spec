defmodule CodeMySpec.WorkingCopiesUniquenessTest do
  @moduledoc """
  Device and root, as far as the database constrains a checkout's identity.

  Issue cb01ce40 added a unique index on `{project, device, root}` because the
  working-copies page listed several rows for one path, byte-for-byte
  identical and with no means of telling them apart. 45c044d1 (story 1000,
  criterion 5) removed that index: it backstopped the join-path lookup that
  criterion 5 forbids, and a join with no id must now succeed at minting a
  fresh identity even when another row already names its device and root.
  That reopens cb01ce40's duplicate-row symptom on the page -- a harness that
  cannot keep its id file produces an indistinguishable row every time it
  rejoins. Reclaiming those is its own piece of work, not this one.

  What is left, and still true: the device is still what tells two machines
  at the same path apart, and the root is still what tells two checkouts on
  one machine apart. Neither of those ever depended on the removed index.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Repo
  alias CodeMySpec.WorkingCopies.WorkingCopy

  setup do
    scope = full_scope_fixture()
    %{scope: scope, device: device_fixture(scope)}
  end

  defp copy_at(scope, device, root) do
    %WorkingCopy{}
    |> WorkingCopy.changeset(%{
      project_id: scope.active_project_id,
      device_id: device.id,
      root: root,
      label: "the harness at #{root}"
    })
    |> Repo.insert()
  end

  test "a second copy at the same path on the same machine is allowed, not refused", %{
    scope: scope,
    device: device
  } do
    assert {:ok, _first} = copy_at(scope, device, "/workspace/app")

    assert {:ok, _second} = copy_at(scope, device, "/workspace/app"),
           "the unique index this used to hit (working_copies_project_device_root_index) " <>
             "has to be gone along with the lookup it backstopped -- criterion 5 requires " <>
             "a join with no id to mint and report its root successfully even when another " <>
             "row already claims that device and root (45c044d1)"
  end

  test "the same path on a different machine is a different checkout", %{
    scope: scope,
    device: device
  } do
    other = device_fixture(scope, %{hostname: "another-box"})

    assert {:ok, _} = copy_at(scope, device, "/workspace/app")

    assert {:ok, _} = copy_at(scope, other, "/workspace/app"),
           "two boxes with a checkout at the same path were treated as one. That is " <>
             "the reason the device is in the key at all -- `/workspace/app` is the " <>
             "default path in every container."
  end

  test "a different path on the same machine is a different checkout", %{
    scope: scope,
    device: device
  } do
    assert {:ok, _} = copy_at(scope, device, "/workspace/app")
    assert {:ok, _} = copy_at(scope, device, "/workspace/app/.claude/worktrees/one")
  end
end
