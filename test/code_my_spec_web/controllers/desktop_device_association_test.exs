defmodule CodeMySpecWeb.DesktopDeviceAssociationTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures
  import CodeMySpec.AccountsFixtures

  alias CodeMySpec.Devices
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.UserPreferences.DesktopUser
  alias CodeMySpec.Users.Scope
  alias CodeMySpecWeb.DeviceController.DesktopAssociation

  setup do
    previous =
      Map.new(
        [:env, :device_config_path, :desktop_device_associator],
        &{&1, Application.get_env(:code_my_spec, &1)}
      )

    file =
      Path.join(
        System.tmp_dir!(),
        "cms-device-association-#{System.unique_integer([:positive])}.json"
      )

    Application.put_env(:code_my_spec, :env, :desktop)

    Application.put_env(
      :code_my_spec,
      :desktop_device_associator,
      {DesktopAssociation, :associate_current}
    )

    Application.put_env(:code_my_spec, :device_config_path, file)

    on_exit(fn ->
      File.rm(file)

      for {key, value} <- previous do
        CodeMySpecTest.EnvRestore.restore_app_env(key, value)
      end
    end)

    user = user_fixture(%{email: DesktopUser.email()})
    id = Ecto.UUID.generate()
    File.write!(file, Jason.encode!(%{device_id: id}))
    {:ok, device} = Devices.announce(%Scope{}, id, %{kind: :local, hostname: "desktop"})
    %{user: user, device: device}
  end

  test "selecting the first account exposes the desktop device before its next announcement", %{
    user: user,
    device: device
  } do
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    assert Repo.get!(Device, device.id).account_id == nil
    assert {:ok, _} = CodeMySpec.UserPreferences.select_active_account(scope, account.id)
    assert Repo.get!(Device, device.id).account_id == account.id
    assert Enum.any?(Devices.list_harness_devices(scope), &(&1.id == device.id))
    assert Repo.aggregate(Device, :count) == 1
  end

  test "harness discovery retains a user's device when switching accounts without exposing strangers",
       %{user: user, device: device} do
    original = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, original)
    CodeMySpec.UserPreferences.select_active_account(scope, original.id)
    next = account_with_owner_fixture(user)
    scope = %{scope | active_account_id: next.id}
    CodeMySpec.UserPreferences.select_active_account(scope, next.id)
    assert Repo.get!(Device, device.id).account_id == original.id
    assert Enum.any?(Devices.list_harness_devices(scope), &(&1.id == device.id))
    stranger = user_fixture()
    other_scope = user_scope_fixture(stranger, account_with_owner_fixture(stranger))
    refute Enum.any?(Devices.list_harness_devices(other_scope), &(&1.id == device.id))
  end

  test "accountless boot keeps its machine identity after account creation", %{
    user: user,
    device: device
  } do
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    assert :ok = DesktopAssociation.associate(scope, device.id)
    assert {:ok, first} = Devices.announce(scope, device.id, %{kind: :local})
    assert {:ok, second} = Devices.announce(scope, device.id, %{kind: :local})
    assert first.id == device.id
    assert second.id == device.id
    assert first.account_id == account.id
    assert Devices.get_harness_device(scope, device.id).id == device.id
    assert Repo.aggregate(Device, :count) == 1
  end

  test "another signed-in user cannot claim the desktop machine", %{device: device} do
    other = user_fixture()
    scope = user_scope_fixture(other, account_with_owner_fixture(other))
    assert :ok = DesktopAssociation.associate(scope, device.id)
    assert Repo.get!(Device, device.id).account_id == nil
  end

  test "request UUID cannot claim another accountless device", %{user: user} do
    scope = user_scope_fixture(user, account_with_owner_fixture(user))
    {:ok, other} = Devices.announce(%Scope{}, nil, %{kind: :local})
    assert :ok = DesktopAssociation.associate(scope, other.id)
    assert Repo.get!(Device, other.id).account_id == nil
  end

  test "web and unauthorized accounts never adopt accountless devices", %{
    user: user,
    device: device
  } do
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    Application.put_env(:code_my_spec, :env, :test)
    assert :ok = DesktopAssociation.associate(scope, device.id)
    assert Repo.get!(Device, device.id).account_id == nil
    Application.put_env(:code_my_spec, :env, :desktop)
    other = account_with_owner_fixture(user_fixture())
    assert :ok = DesktopAssociation.associate(%{scope | active_account_id: other.id}, device.id)
    assert Repo.get!(Device, device.id).account_id == nil
  end

  test "existing ownership is never moved", %{user: user, device: device} do
    original = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, original)
    DesktopAssociation.associate(scope, device.id)
    another = account_with_owner_fixture(user)
    DesktopAssociation.associate(%{scope | active_account_id: another.id}, device.id)
    assert Repo.get!(Device, device.id).account_id == original.id
  end
end
