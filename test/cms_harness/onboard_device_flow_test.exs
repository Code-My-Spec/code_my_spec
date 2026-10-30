defmodule CmsHarness.OnboardDeviceFlowTest do
  use CodeMySpecTest.DataCase, async: false

  import ExUnit.CaptureIO

  alias CmsHarness.HarnessConfig
  alias CmsHarness.Onboarding
  alias CmsHarnessTest.Projects
  alias CodeMySpec.Auth.HarnessOAuth

  test "a fresh checkout mints with device approval and no deploy key" do
    server = "http://127.0.0.1:4000"
    verification_uri = "https://device-onboarding.example.test/verify"

    %{root: root, id: project_id} =
      Projects.project_dir(project_id: Ecto.UUID.generate(), working_copy_id: nil)

    dir = CodeMySpec.TempFile.owned_dir("onboard_device_flow")
    previous_key = System.get_env("CMS_DEPLOY_KEY")

    keys = [
      :harness_deploy_key,
      :harness_token,
      :harness_dev_box,
      :onboard_device_id,
      :device_config_path,
      :harness_server_url_override,
      HarnessOAuth,
      Onboarding
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:code_my_spec, &1)})

    System.delete_env("CMS_DEPLOY_KEY")
    Application.delete_env(:code_my_spec, :harness_deploy_key)
    Application.delete_env(:code_my_spec, :harness_token)
    Application.delete_env(:code_my_spec, :harness_dev_box)
    Application.put_env(:code_my_spec, :device_config_path, Path.join(dir, "device.json"))
    Application.put_env(:code_my_spec, :onboard_device_id, Ecto.UUID.generate())
    Application.put_env(:code_my_spec, :harness_server_url_override, server)

    Application.put_env(:code_my_spec, HarnessOAuth,
      state_dir: dir,
      plug: {Req.Test, HarnessOAuth}
    )

    Application.put_env(:code_my_spec, Onboarding, plug: {Req.Test, Onboarding})

    on_exit(fn ->
      System.delete_env("CMS_DEPLOY_KEY")
      Enum.each(List.wrap(previous_key), &System.put_env("CMS_DEPLOY_KEY", &1))

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:code_my_spec, key, value)
        {key, :error} -> Application.delete_env(:code_my_spec, key)
      end)
    end)

    Req.Test.stub(HarnessOAuth, fn
      %{request_path: "/oauth/register"} = conn ->
        Req.Test.json(conn, %{client_id: "new-client", client_secret: "new-secret"})

      %{request_path: "/oauth/device/code"} = conn ->
        Req.Test.json(conn, %{
          device_code: "private-code",
          user_code: "ABCD-EFGH",
          verification_uri: verification_uri,
          expires_in: 600,
          interval: 1
        })

      %{request_path: "/oauth/token"} = conn ->
        Req.Test.json(conn, %{
          access_token: "approved-token",
          refresh_token: "refresh-token",
          expires_in: 7200
        })
    end)

    Req.Test.stub(Onboarding, fn conn ->
      assert conn.request_path == "/api/harnesses"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer approved-token"]
      Req.Test.json(conn, %{harness_id: "approved-copy"})
    end)

    output =
      capture_io(fn ->
        assert {:ok, "approved-copy"} =
                 Onboarding.mint(root, project_id, authorize: true, sleep: fn _ -> :ok end)
      end)

    assert output =~ verification_uri
    assert output =~ "ABCD-EFGH"
    assert {:ok, config} = HarnessConfig.read_file(root)
    assert config.working_copy_id == "approved-copy"
    assert config.server_url == server
    assert config.deploy_key == nil

    assert {:ok, "approved-token"} =
             HarnessOAuth.access_token(server, Application.get_env(:code_my_spec, HarnessOAuth))
  end
end
