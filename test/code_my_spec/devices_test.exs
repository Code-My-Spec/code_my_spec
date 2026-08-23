defmodule CodeMySpec.DevicesTest do
  @moduledoc """
  The machine a working copy sits on.

  Three things this has to get right, and each of them is a way the level below
  already went wrong once:

    * **Announcing is idempotent.** A daemon presents the id it holds and is
      recognised. If it were not, every reconnect would mint another machine and
      the list would fill with duplicates of one laptop — which is exactly what
      `harnesses` does today when a checkout joins without its id.
    * **The id is scoped.** It arrives from a machine, so it is an input. An id
      belonging to another account must not be handed over.
    * **Absence is a state.** A daemon built before devices sends nothing, gets
      no device, and its copies keep a null — "we have not been told", which is
      different from a machine that reported and is different again from a
      failure.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.WorkingCopies

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "announcing a machine" do
    test "a machine with no id is issued one", %{scope: scope} do
      assert {:ok, device} =
               Devices.announce(scope, nil, %{hostname: "Johns-Mac-mini", kind: :local})

      assert device.id
      assert device.hostname == "Johns-Mac-mini"
      assert device.kind == :local
      assert device.last_seen_at
    end

    test "presenting the id again is the same machine, not a second one", %{scope: scope} do
      {:ok, first} = Devices.announce(scope, nil, %{hostname: "Johns-Mac-mini", kind: :local})

      {:ok, again} =
        Devices.announce(scope, first.id, %{hostname: "Johns-Mac-mini", kind: :local})

      assert again.id == first.id

      assert length(Devices.list_devices(scope)) == 1,
             "a reconnect that mints a new machine fills the list with duplicates of " <>
               "one laptop, which is the failure the working-copy level has today"
    end

    test "what the machine says about itself is taken on every announce", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "old-name", kind: :local})
      {:ok, updated} = Devices.announce(scope, device.id, %{hostname: "new-name", kind: :cloud})

      assert updated.id == device.id

      assert {updated.hostname, updated.kind} == {"new-name", :cloud},
             "a box gets re-imaged, renamed, or re-provisioned from a laptop into a " <>
               "sprite. A record that kept only the first answer describes the machine " <>
               "as it was when it first appeared."
    end

    test "an id from another account is not handed over", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = Devices.announce(other, nil, %{hostname: "not-yours", kind: :local})

      {:ok, mine} = Devices.announce(scope, theirs.id, %{hostname: "mine", kind: :local})

      refute mine.id == theirs.id,
             "the id arrives from a machine, so it is an input. Trusting it unscoped " <>
               "hands one account's device to another's daemon."

      assert Devices.get_device(scope, theirs.id) == nil
    end

    test "a malformed id mints rather than crashing", %{scope: scope} do
      assert {:ok, device} = Devices.announce(scope, "not-a-uuid", %{hostname: "h", kind: :local})
      assert device.id
    end
  end

  describe "attaching a working copy" do
    test "a copy records the machine it is on", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "Johns-Mac-mini", kind: :local})
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout")

      assert {:ok, attached} = Devices.attach(copy, device)
      assert attached.device_id == device.id
    end

    test "no device announced leaves the copy unattached, and that is a state", %{scope: scope} do
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout")

      assert {:ok, same} = Devices.attach(copy, nil)

      assert same.device_id == nil,
             "a daemon built before devices announces none. Null means 'we have not " <>
               "been told', which has to stay distinguishable from a machine that reported."
    end

    test "a copy that moves machines re-attaches", %{scope: scope} do
      {:ok, laptop} = Devices.announce(scope, nil, %{hostname: "laptop", kind: :local})
      {:ok, sprite} = Devices.announce(scope, nil, %{hostname: "sprite", kind: :cloud})
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout")

      {:ok, copy} = Devices.attach(copy, laptop)
      {:ok, moved} = Devices.attach(copy, sprite)

      assert moved.device_id == sprite.id,
             "the copy's identity is its own and does not belong to the box, so a " <>
               "checkout that turns up on another machine re-attaches rather than being refused"
    end
  end

  describe "naming a machine" do
    test "a chosen name wins over the hostname", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "Johns-Mac-mini", kind: :local})

      assert Device.display_name(device) == "Johns-Mac-mini"

      {:ok, named} = Devices.relabel(scope, device, "the mini")
      assert Device.display_name(named) == "the mini"
    end

    test "blank clears it and the hostname comes back", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "Johns-Mac-mini", kind: :local})
      {:ok, named} = Devices.relabel(scope, device, "the mini")

      {:ok, cleared} = Devices.relabel(scope, named, "   ")

      assert cleared.label == nil
      assert Device.display_name(cleared) == "Johns-Mac-mini"
    end

    test "a machine with neither is still distinguishable", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{})

      assert Device.display_name(device) == String.slice(device.id, 0, 8),
             "a blank cell reads as a rendering bug rather than as a machine nobody named"
    end

    test "another account's device cannot be renamed", %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = Devices.announce(other, nil, %{hostname: "not-yours", kind: :local})

      assert {:error, :not_yours} = Devices.relabel(scope, theirs, "mine now")
    end
  end
end
