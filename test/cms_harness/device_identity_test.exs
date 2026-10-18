defmodule CmsHarness.DeviceIdentityTest do
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CmsHarness.Device
  alias CodeMySpec.Devices

  setup do
    scope = full_scope_fixture()
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
