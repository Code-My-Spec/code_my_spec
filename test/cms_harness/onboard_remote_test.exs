defmodule CmsHarness.OnboardRemoteTest do
  use CodeMySpecTest.DataCase, async: false

  alias CmsHarness.Config
  alias CmsHarness.Credentials
  alias CmsHarness.Device
  alias CmsHarness.Device.Client.Http
  alias CmsHarness.HarnessConfig
  alias CmsHarness.Token
  alias CmsHarnessTest.FakeServer
  alias CmsHarnessTest.Projects
  alias Mix.Tasks.Cms.Harness.Onboard

  setup do
    server = FakeServer.start()

    previous =
      Map.new(
        [
          :device_config_path,
          :device_client,
          :harness_token,
          :harness_deploy_key,
          :onboard_device_id,
          Token,
          Http
        ],
        fn key ->
          {key, Application.fetch_env(:code_my_spec, key)}
        end
      )

    dir = CodeMySpec.TempFile.owned_dir("remote_onboard_device")
    device_file = Path.join(dir, "device.json")
    Application.put_env(:code_my_spec, :device_config_path, device_file)
    Application.put_env(:code_my_spec, :device_client, Http)
    Application.delete_env(:code_my_spec, :harness_token)
    Application.delete_env(:code_my_spec, :harness_deploy_key)
    Application.put_env(:code_my_spec, Token, plug: {Req.Test, Token})
    Application.put_env(:code_my_spec, Http, plug: {Req.Test, Http})
    System.put_env("CMS_DEPLOY_KEY", "remote-project-fixture-key")
    Token.invalidate()

    on_exit(fn ->
      Enum.each(previous, fn {key, value} -> restore(key, value) end)
      Token.invalidate()
    end)

    %{root: root, id: project_id} =
      Projects.project_dir(project_id: Ecto.UUID.generate(), working_copy_id: nil)

    copy_id = Ecto.UUID.generate()
    parent = self()

    Req.Test.stub(Token, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer remote-project-fixture-key"
             ]

      json(conn, %{access_token: "onboarding-fixture-token", expires_in: 3600})
    end)

    allow_token_process(Process.whereis(Token))

    Req.Test.stub(Http, fn conn ->
      assert conn.request_path == "/api/devices"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Bearer onboarding-fixture-token"
             ]

      {:ok, body, conn} = Plug.Conn.read_body(conn)
      id = Jason.decode!(body)["device_id"]
      assert is_binary(id)
      send(parent, {:registered_device, id})
      json(conn, %{device_id: id, working_copies: %{}})
    end)

    Req.Test.stub(Onboard, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/harnesses"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = Jason.decode!(body)
      assert payload["project_id"] == project_id
      assert payload["device_id"] == Device.recorded_id()
      assert_received {:registered_device, device_id}
      assert payload["device_id"] == device_id
      json(conn, %{harness_id: copy_id})
    end)

    %{
      root: root,
      project_id: project_id,
      copy_id: copy_id,
      device_file: device_file,
      server: server
    }
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:code_my_spec, key, value)
  defp restore(key, :error), do: Application.delete_env(:code_my_spec, key)
  defp allow_token_process(nil), do: :ok
  defp allow_token_process(pid), do: Req.Test.allow(Token, self(), pid)

  defp json(conn, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))

  defp onboard(root), do: Onboard.run([root, "--server-url", "https://remote-onboarding.invalid"])

  test "confirmation uses the local project's key despite an unrelated exported key", ctx do
    scope = CodeMySpec.UsersFixtures.full_scope_fixture()
    project = CodeMySpec.ProjectsFixtures.project_fixture(scope)
    %{root: root, working_copy_id: copy_id} = Projects.project_dir(project_id: project.id)
    parent = self()

    Req.Test.stub(Onboard, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/harnesses/#{copy_id}"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer " <> project.deploy_key]
      send(parent, :confirmed_with_project_key)
      json(conn, %{})
    end)

    Onboard.run([
      root,
      "--server-url",
      "http://127.0.0.1:#{ctx.server.port}",
      "--project",
      project.id
    ])

    assert_received :confirmed_with_project_key
    assert {:ok, config} = HarnessConfig.read_file(root)
    assert config.working_copy_id == copy_id
    assert config.deploy_key == project.deploy_key
  end

  test "a fresh remote machine registers before receiving a copy id and credential", ctx do
    refute File.exists?(ctx.device_file)
    onboard(ctx.root)
    assert {:ok, config} = HarnessConfig.read_file(ctx.root)
    assert config.working_copy_id == ctx.copy_id
    assert config.project_id == ctx.project_id
    assert config.deploy_key == "remote-project-fixture-key"
    assert is_binary(Device.recorded_id())
  end

  test "a recorded device is announced again before minting", ctx do
    id = Ecto.UUID.generate()
    File.write!(ctx.device_file, Jason.encode!(%{device_id: id}))
    onboard(ctx.root)
    assert Device.recorded_id() == id
    assert {:ok, %{working_copy_id: copy_id}} = HarnessConfig.read_file(ctx.root)
    assert copy_id == ctx.copy_id
  end

  test "the onboarded copy connects after the exported deploy key is removed", ctx do
    onboard(ctx.root)
    System.delete_env("CMS_DEPLOY_KEY")

    assert {:ok, "remote-project-fixture-key", :working_copy_key} =
             Credentials.for_working_copy(ctx.root)

    # HTTP onboarding uses Req.Test; the websocket uses a real local listener.
    # Change only its destination, preserving the credential onboarding wrote.
    assert :ok =
             HarnessConfig.write(ctx.root, %{
               working_copy_id: ctx.copy_id,
               server_url: "http://127.0.0.1:#{ctx.server.port}"
             })

    assert {:ok, uri} = Config.socket_url(ctx.root)
    assert URI.decode_query(URI.parse(uri).query)["token"] == "remote-project-fixture-key"
    on_exit(fn -> Projects.stop_project(ctx.root) end)
    assert {:ok, _} = Projects.ensure_started(ctx.root)
    copy_id = ctx.copy_id
    assert_receive {:joined, _, %{"harness_id" => ^copy_id}}, 10_000
  end
end
