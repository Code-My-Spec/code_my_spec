defmodule CmsHarness.DeviceIdentityTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CmsHarness.Device
  alias CodeMySpec.Devices

  setup do
    scope = full_scope_fixture()

    CodeMySpec.Repo.get_by!(CodeMySpec.Accounts.Member,
      user_id: scope.user.id,
      account_id: scope.active_account_id
    )
    |> CodeMySpec.Accounts.Member.update_role_changeset(%{role: :owner})
    |> CodeMySpec.Repo.update!()

    token = "dk_device_identity_#{System.unique_integer([:positive])}"

    {:ok, _project} =
      CodeMySpec.Projects.update_project(scope, scope.active_project, %{deploy_key: token})

    dir =
      Path.join(File.cwd!(), "_build/test/device_identity_#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    keys = [:device_config_path, :device_client, :project_id]
    previous = Map.new(keys, &{&1, Application.fetch_env(:code_my_spec, &1)})

    on_exit(fn ->
      Enum.each(previous, &restore/1)
      File.rm_rf!(dir)
    end)

    Application.put_env(:code_my_spec, :device_client, CodeMySpecTest.InProcessDeviceClient)
    Application.put_env(:code_my_spec, :project_id, scope.active_project.id)

    :ok = :meck.new(:inet, [:passthrough, :no_link, :unstick])
    on_exit(fn -> :meck.unload(:inet) end)

    %{scope: scope, token: token, dir: dir}
  end

  test "fresh harness identities survive virtual interface changes and distinguish machines", %{
    scope: scope,
    token: token,
    dir: dir
  } do
    existing = device_ids(scope)
    hardware = [148, 5, 187, 209, 94, 222]
    other_hardware = [148, 5, 187, 209, 94, 223]
    first_virtual = [10, 177, 72, 229, 214, 212]
    second_virtual = [38, 133, 99, 127, 183, 12]

    first =
      announce_from(dir, "first-boot", token, [
        {~c"awdl0", [flags: [:up], hwaddr: first_virtual]},
        {~c"en0", [flags: [:up], hwaddr: hardware]}
      ])

    assert device_ids(scope) -- existing == [first]

    # Separate files force both boots to fingerprint the interfaces independently.
    second =
      announce_from(dir, "second-boot", token, [
        {~c"en0", [flags: [:up], hwaddr: hardware]},
        {~c"awdl0", [flags: [:up], hwaddr: second_virtual]}
      ])

    assert second == first
    assert device_ids(scope) -- existing == [first]

    third =
      announce_from(dir, "other-machine", token, [
        {~c"awdl0", [flags: [:up], hwaddr: second_virtual]},
        {~c"en0", [flags: [:up], hwaddr: other_hardware]}
      ])

    refute third == first
    assert Enum.sort(device_ids(scope) -- existing) == Enum.sort([first, third])
    assert :meck.validate(:inet)
  end

  # Several QA harnesses on one machine, each a device of its own.
  test "a harness with its own state dir is its own device on the same hardware", %{
    scope: scope,
    token: token,
    dir: dir
  } do
    existing = device_ids(scope)
    interfaces = [{~c"en0", [flags: [:up], hwaddr: [148, 5, 187, 209, 94, 222]]}]
    previous = System.get_env("CMS_PROJECT_DIR")
    on_exit(fn -> restore_env("CMS_PROJECT_DIR", previous) end)

    ids =
      for name <- ["device-a", "device-b"] do
        System.put_env("CMS_PROJECT_DIR", Path.join([dir, name, "copy"]))
        announce_from(dir, name, token, interfaces)
      end

    assert [a, b] = ids
    refute a == b
    assert Enum.sort(device_ids(scope) -- existing) == Enum.sort(ids)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)

  defp announce_from(dir, name, token, interfaces) do
    file = Path.join(dir, name <> ".json")
    refute File.exists?(file)
    Application.put_env(:code_my_spec, :device_config_path, file)
    :ok = :meck.expect(:inet, :getifaddrs, fn -> {:ok, interfaces} end)

    assert {:ok, %{device_id: id}} = Device.announce(%{}, token)
    assert Device.recorded_id() == id
    assert %{"device_id" => ^id} = file |> File.read!() |> Jason.decode!()
    id
  end

  defp device_ids(scope), do: scope |> Devices.list_devices() |> Enum.map(& &1.id)

  defp restore({key, :error}), do: Application.delete_env(:code_my_spec, key)
  defp restore({key, {:ok, value}}), do: Application.put_env(:code_my_spec, key, value)
end
