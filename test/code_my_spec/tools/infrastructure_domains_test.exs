defmodule CodeMySpec.Tools.InfrastructureDomainsTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.ToolLibrary

  test "infrastructure tools have one canonical registration in their owning domain" do
    expected = [
      {"list_devices", CodeMySpec.Devices.Tools.ListDevices},
      {"get_device", CodeMySpec.Devices.Tools.GetDevice},
      {"list_app_instances", CodeMySpec.AppInstances.Tools.ListAppInstances},
      {"get_app_instance", CodeMySpec.AppInstances.Tools.GetAppInstance},
      {"ensure_environment", CodeMySpec.Environments.Tools.EnsureEnvironment},
      {"assign_environment_device", CodeMySpec.Environments.Tools.AssignEnvironmentDevice}
    ]

    registrations = ToolLibrary.registrations()

    for {name, module} <- expected do
      assert [registration] = Enum.filter(registrations, &(&1.name == name))
      assert registration.tool == module
    end
  end

  test "all agent roles can inspect infrastructure but only Main can change placement" do
    for role <- RoleProfile.roles(),
        name <- ~w(list_devices get_device list_app_instances get_app_instance list_environments) do
      assert RoleProfile.carries?(role, name)
    end

    for name <- ~w(ensure_environment assign_environment_device assign_app_instance_environment) do
      assert RoleProfile.carries?(:main, name)
      refute RoleProfile.carries?(:product, name)
      refute RoleProfile.carries?(:coding, name)
      refute RoleProfile.carries?(:qa, name)
    end
  end

  test "device assignment advertises both required canonical identifiers" do
    {:ok, tool} = ToolLibrary.fetch("assign_environment_device")
    schema = ToolLibrary.registration(tool).input_schema
    assert Enum.sort(schema["required"]) == ["device_id", "environment_id"]
    assert schema["properties"]["device_id"]["type"] == "string"
    assert schema["properties"]["environment_id"]["type"] == "string"
  end

  test "Lua composes device, environment and instance tools without a working copy" do
    scope = %{CodeMySpec.UsersFixtures.full_scope_fixture() | active_working_copy_id: nil}
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)

    {:ok, instance} =
      CodeMySpec.AppInstances.create(scope, %{
        checked_at: DateTime.utc_now(),
        port_mode: :configured,
        database_mode: :configured
      })

    frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

    script = ~s"""
    ensure_environment({name = "development", management = "harness"})
    local devices = list_devices({})
    local device = get_device({device_id = "#{device.id}"})
    local environments = list_environments({})
    local instances = list_app_instances({})
    local selected = get_app_instance({instance_id = "#{instance.id}"})
    assign_environment_device({environment_id = environments[1].id, device_id = device.id})
    assign_app_instance_environment({environment_id = environments[1].id, instance_id = selected.id})
    local instance = get_app_instance({instance_id = selected.id})
    return {device_id = device.id, instance_id = instance.id, checked_at = instance.checked_at}
    """

    assert {:reply, response, ^frame} =
             CodeMySpec.McpServers.CodeMode.Tools.RunScript.execute(%{script: script}, frame)

    refute response.isError

    text =
      response
      |> Anubis.Server.Response.to_protocol()
      |> Map.fetch!("content")
      |> hd()
      |> Map.fetch!("text")

    assert text =~ device.id
    assert text =~ instance.id
    assert text =~ DateTime.to_iso8601(instance.checked_at)
    environment = CodeMySpec.Environments.get(scope, "development")
    assert environment.device_id == device.id
    assert CodeMySpec.AppInstances.get(scope, instance.id).environment_id == environment.id
  end
end
