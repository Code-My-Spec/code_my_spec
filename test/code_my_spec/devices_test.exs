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
    * **Absence is refused, not recorded.** It used to be a state: a daemon
      built before devices sent nothing, got no device, and its copies kept a
      null meaning "we have not been told". `working_copies.device_id` and
      `devices.kind` are both required now — a checkout is identified by
      {project, device, root}, and a machine that will not say what it is
      cannot answer the question `kind` exists for. A client that says neither
      is turned away rather than written down as an unknown.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.Users.Scope
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

      before = length(Devices.list_devices(scope))

      {:ok, again} =
        Devices.announce(scope, first.id, %{hostname: "Johns-Mac-mini", kind: :local})

      assert again.id == first.id

      # Counted as a difference rather than against one, because the scope
      # arrives holding a machine of its own now: `working_copies.device_id` is
      # required, so the fixture that mints this scope's checkout has to mint a
      # device for it too. What this asserts is unchanged — the second announce
      # added nothing.
      assert length(Devices.list_devices(scope)) == before,
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

    test "a machine's own well-formed id, never seen before, is created rather than replaced",
         %{scope: scope} do
      minted = Ecto.UUID.generate()

      assert {:ok, device} =
               Devices.announce(scope, minted, %{hostname: "a-new-laptop", kind: :local})

      assert device.id == minted,
             "the machine minted this id itself and presented it as a fact. Handing back " <>
               "a different one on a first announce is the server re-asserting an identity " <>
               "the client already settled — the exact behaviour that raced two daemons on " <>
               "one box against a single shared device.json."
    end

    test "two daemons racing to create the same new id both land on one device",
         %{scope: scope} do
      minted = Ecto.UUID.generate()

      {:ok, first} = Devices.announce(scope, minted, %{hostname: "daemon-a", kind: :local})

      assert {:ok, second} =
               Devices.announce(scope, minted, %{hostname: "daemon-b", kind: :local})

      assert second.id == first.id,
             "losing the race to create your own device is not a reason to be refused it"

      assert Devices.list_devices(scope) |> Enum.count(&(&1.id == minted)) == 1
    end

    test "a machine's own id colliding with a different account's device gets a fresh one",
         %{scope: scope} do
      other = full_scope_fixture()
      {:ok, theirs} = Devices.announce(other, nil, %{hostname: "not-yours", kind: :local})

      assert {:ok, mine} =
               Devices.announce(scope, theirs.id, %{hostname: "mine", kind: :local})

      refute mine.id == theirs.id,
             "a self-picked id is not guaranteed unique across accounts the way a " <>
               "server-minted one was; a collision must not hand this announce " <>
               "another account's device"

      assert mine.account_id == scope.active_account_id
    end
  end

  describe "a machine that belongs to nobody" do
    test "a shared box is issued an identity without an account" do
      assert {:ok, device} =
               Devices.announce(%Scope{}, nil, %{hostname: "the-shared-box", kind: :local})

      assert device.id
      assert device.account_id == nil

      assert device.hostname == "the-shared-box",
             "a shared development box holds no project and belongs to no one " <>
               "account. Requiring one would attach it to whichever account " <>
               "happened to announce first."
    end

    test "it recognises itself across restarts" do
      {:ok, first} = Devices.announce(%Scope{}, nil, %{hostname: "the-shared-box", kind: :local})

      {:ok, again} =
        Devices.announce(%Scope{}, first.id, %{hostname: "the-shared-box", kind: :local})

      assert again.id == first.id
    end

    test "an accountless announce cannot reach an account's machine", %{scope: scope} do
      {:ok, owned} = Devices.announce(scope, nil, %{hostname: "a-laptop", kind: :local})

      {:ok, shared} =
        Devices.announce(%Scope{}, owned.id, %{hostname: "the-shared-box", kind: :local})

      refute shared.id == owned.id,
             "presenting a real device id with no credentials behind it was " <>
               "answered with that account's machine. A nil account has to match " <>
               "only other nil-account devices, or 'belongs to nobody' becomes a " <>
               "way to reach anybody."

      assert shared.account_id == nil
    end
  end

  describe "attaching a working copy" do
    test "a copy records the machine it is on", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "Johns-Mac-mini", kind: :local})
      {:ok, other} = Devices.announce(scope, nil, %{hostname: "somewhere-else", kind: :local})
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout", device: other)

      assert {:ok, attached} = Devices.attach(copy, device)
      assert attached.device_id == device.id
    end

    test "attaching nothing leaves the copy on the machine it already had", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "a-laptop", kind: :local})
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout", device: device)

      assert {:ok, same} = Devices.attach(copy, nil)

      assert same.device_id == device.id,
             "a join that announces no device must not detach the copy from the machine " <>
               "that minted it. This used to assert the copy stayed unattached, which was " <>
               "a state a copy could be in before `device_id` was required — it is not one now."
    end

    test "a copy that moves machines re-attaches", %{scope: scope} do
      {:ok, laptop} = Devices.announce(scope, nil, %{hostname: "laptop", kind: :local})
      {:ok, sprite} = Devices.announce(scope, nil, %{hostname: "sprite", kind: :cloud})
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout", device: laptop)

      {:ok, copy} = Devices.attach(copy, laptop)
      {:ok, moved} = Devices.attach(copy, sprite)

      assert moved.device_id == sprite.id,
             "the copy's identity is its own and does not belong to the box, so a " <>
               "checkout that turns up on another machine re-attaches rather than being refused"
    end
  end

  describe "staying alive" do
    test "a copy proving it is alive proves its machine alive too", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{hostname: "a-laptop", kind: :local})
      {:ok, copy} = WorkingCopies.issue(scope, nil, label: "a checkout", device: device)

      # Back-date the machine so a touch is observable. Announcing stamped it a
      # moment ago, and comparing two timestamps from the same millisecond
      # proves nothing either way.
      stale = DateTime.add(DateTime.utc_now(), -3600, :second)

      {:ok, _} =
        device
        |> Ecto.Changeset.change(last_seen_at: stale)
        |> CodeMySpec.Repo.update()

      :ok = WorkingCopies.mark_alive(copy)

      refreshed = Devices.get_device(scope, device.id)

      assert DateTime.compare(refreshed.last_seen_at, stale) == :gt,
             "the machine's liveness was only ever its boot time, so every device " <>
               "read 'Last seen' two minutes after starting — observed live with " <>
               "the harness connected and serving at that moment"
    end

    test "a copy on no machine marks nothing and does not raise", %{scope: scope} do
      {:ok, copy} =
        WorkingCopies.issue(scope, nil,
          label: "an unattached checkout",
          device: device_fixture(scope)
        )

      assert :ok = WorkingCopies.mark_alive(copy),
             "bookkeeping alongside a request that has real work to do must not " <>
               "be able to fail the request"
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

    # Neither *name*. `kind` is required — a machine that will not say what it is
    # is refused rather than recorded — so the nameless case still says that
    # much about itself.
    test "a machine with neither is still distinguishable", %{scope: scope} do
      {:ok, device} = Devices.announce(scope, nil, %{kind: :local})

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
