defmodule CmsHarness.DevBoxTokenExchangeTest do
  @moduledoc """
  Story 1131: a harness running as a dev box trades its box token for an access
  token, and presents that, never the box token itself. In Claude Code cloud it
  holds no box token and sends none: the proxy adds the header in transit.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Config
  alias CmsHarness.Credentials
  alias CmsHarness.Token

  @keys [:harness_dev_box, :harness_device_token, :harness_deploy_key, :harness_token]

  setup do
    previous = for key <- @keys, do: {key, Application.get_env(:code_my_spec, key)}
    plug = Application.get_env(:code_my_spec, Token)

    env =
      for name <- [
            "CMS_DEV_BOX",
            "CMS_DEVICE_TOKEN",
            "CMS_DEPLOY_KEY",
            "CMS_TOKEN",
            "CMS_DEVICE_TOKEN_FILE"
          ],
          do: {name, System.get_env(name)}

    Enum.each(@keys, &Application.delete_env(:code_my_spec, &1))
    Enum.each(env, fn {name, _} -> System.delete_env(name) end)
    Application.put_env(:code_my_spec, Token, plug: {Req.Test, Token})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> Application.delete_env(:code_my_spec, key)
        {key, value} -> Application.put_env(:code_my_spec, key, value)
      end)

      restore(Token, plug)

      Enum.each(env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)

    test_pid = self()

    Req.Test.stub(Token, fn conn ->
      send(
        test_pid,
        {:exchange, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")}
      )

      Req.Test.json(conn, %{"access_token" => "access-1", "expires_in" => 3600})
    end)

    # The exchange runs in the token process, with nothing cached from another test.
    Req.Test.allow(Token, self(), Process.whereis(Token))
    :ok = Token.invalidate()
    _ = :sys.get_state(Token)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore(key, value), do: Application.put_env(:code_my_spec, key, value)

  test "a harness not running as a dev box has no dev box credential" do
    assert {:error, :no_credential} = Credentials.any()
  end

  test "a box token is traded at the box route and the socket gets the access token" do
    Application.put_env(:code_my_spec, :harness_device_token, "cbt_abc")

    assert {:ok, "cbt_abc", :dev_box} = Credentials.any()
    assert {:ok, "access-1"} = Config.credential(nil)

    assert_receive {:exchange, "/api/devices/token", ["Bearer cbt_abc"]}
  end

  test "a cloud box holds no token and sends none" do
    Application.put_env(:code_my_spec, :harness_dev_box, true)

    assert {:ok, "", :dev_box} = Credentials.any()
    assert {:ok, "access-1"} = Token.access_token()

    assert_receive {:exchange, "/api/devices/token", []}
  end

  test "a dev box 401 includes the server refusal and setup remedy" do
    Application.put_env(:code_my_spec, :harness_dev_box, true)

    Req.Test.stub(Token, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        401,
        Jason.encode!(%{
          error: "missing_authorization",
          error_description: "No Authorization header reached the server."
        })
      )
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:refused, 401, reason}} = Token.access_token()
        assert reason =~ "No Authorization header"
      end)

    assert log =~ "Add a dev box"
    assert log =~ "network secret"
    assert log =~ "no 'Bearer ' prefix"
    refute log =~ "CMS_DEPLOY_KEY"
  end

  test "a token mounted as a file is read from it, never from the environment" do
    path = Path.join(System.tmp_dir!(), "cms_token_#{System.unique_integer([:positive])}")
    File.write!(path, "cbt_from_file\n")
    System.put_env("CMS_DEVICE_TOKEN_FILE", path)

    on_exit(fn ->
      System.delete_env("CMS_DEVICE_TOKEN_FILE")
      File.rm(path)
    end)

    assert {:ok, "cbt_from_file"} = Config.device_token()
    assert Config.dev_box?()
  end
end
