defmodule CodeMySpec.Auth.HarnessOAuthTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Auth.HarnessOAuth

  setup do
    dir = CodeMySpec.TempFile.dir("harness-oauth")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{opts: [state_dir: dir, plug: {Req.Test, __MODULE__}], server: "https://auth.example.test"}
  end

  test "registers once, persists approved tokens, and reuses them after restart", ctx do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:request, conn.request_path, body})

      case conn.request_path do
        "/oauth/register" ->
          Req.Test.json(conn, %{client_id: "harness-client", client_secret: "client-secret"})

        "/oauth/device/code" ->
          Req.Test.json(conn, %{
            device_code: "private-code",
            user_code: "ABCD-EFGH",
            verification_uri: "https://auth.example.test/oauth/device",
            expires_in: 600,
            interval: 5
          })

        "/oauth/token" ->
          Req.Test.json(conn, %{
            access_token: "access-one",
            refresh_token: "refresh-one",
            expires_in: 7200
          })
      end
    end)

    device_id = Ecto.UUID.generate()
    assert {:ok, grant} = HarnessOAuth.begin_authorization(ctx.server, device_id, ctx.opts)
    assert grant.user_code == "ABCD-EFGH"
    assert grant.interval == 5
    assert_receive {:request, "/oauth/register", _}
    assert_receive {:request, "/oauth/device/code", body}
    assert URI.decode_query(body)["device_id"] == device_id

    assert {:ok, "access-one"} = HarnessOAuth.poll(ctx.server, grant, ctx.opts)
    assert_receive {:request, "/oauth/token", body}
    assert URI.decode_query(body)["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code"
    assert {:ok, "access-one"} = HarnessOAuth.access_token(ctx.server, ctx.opts)
    refute_receive {:request, _, _}

    assert {:ok, _} = HarnessOAuth.begin_authorization(ctx.server, device_id, ctx.opts)
    assert_receive {:request, "/oauth/device/code", _}
    refute_receive {:request, "/oauth/register", _}
  end

  test "refreshes before expiry and persists rotated credentials privately", ctx do
    path = seed_expiring_credentials(ctx)

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/oauth/token"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      params = URI.decode_query(body)
      assert params["grant_type"] == "refresh_token"
      assert params["refresh_token"] == "old-refresh"
      assert params["client_id"] == "harness-client"
      assert params["client_secret"] == "client-secret"

      Req.Test.json(conn, %{
        access_token: "new-access",
        refresh_token: "new-refresh",
        expires_in: 7200
      })
    end)

    assert {:ok, "new-access"} = HarnessOAuth.access_token(ctx.server, ctx.opts)
    assert {:ok, "new-access"} = HarnessOAuth.access_token(ctx.server, ctx.opts)
    stored = path |> File.read!() |> Jason.decode!()
    assert stored["refresh_token"] == "new-refresh"
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600

    assert {:error, :no_credential} =
             HarnessOAuth.access_token("https://other.example.test", ctx.opts)
  end

  test "rejected refresh remains refused across subsequent reads", ctx do
    path = seed_expiring_credentials(ctx)

    Req.Test.expect(__MODULE__, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: "invalid_grant"})
    end)

    assert {:error, :authorization_required} = HarnessOAuth.access_token(ctx.server, ctx.opts)
    assert {:error, :authorization_required} = HarnessOAuth.access_token(ctx.server, ctx.opts)
    stored = path |> File.read!() |> Jason.decode!()
    refute Map.has_key?(stored, "access_token")
    refute Map.has_key?(stored, "refresh_token")
    assert stored["client_id"] == "harness-client"
  end

  test "expired device grants make no token request", ctx do
    grant = %{deadline: System.monotonic_time(:second) - 1, device_code: "expired"}
    assert {:error, :expired_token} = HarnessOAuth.poll(ctx.server, grant, ctx.opts)
  end

  test "pending, slow-down, denial and expiry preserve the polling response", ctx do
    seed_expiring_credentials(ctx)
    grant = %{deadline: System.monotonic_time(:second) + 600, device_code: "private-code"}

    for {response, expected} <- [
          {"authorization_pending", :authorization_pending},
          {"slow_down", :slow_down},
          {"access_denied", :access_denied},
          {"expired_token", :expired_token}
        ] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.request_path == "/oauth/token"
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{error: response})
      end)

      assert {:error, ^expected} = HarnessOAuth.poll(ctx.server, grant, ctx.opts)
    end
  end

  defp seed_expiring_credentials(ctx) do
    hash = :crypto.hash(:sha256, ctx.server) |> Base.encode16(case: :lower)
    path = Path.join(ctx.opts[:state_dir], "harness_oauth_#{hash}.json")

    File.write!(
      path,
      Jason.encode!(%{
        client_id: "harness-client",
        client_secret: "client-secret",
        access_token: "old-access",
        refresh_token: "old-refresh",
        expires_at: System.system_time(:second) + 120
      })
    )

    path
  end

  test "missing credentials never borrow a user token or deploy key", ctx do
    assert {:error, :no_credential} = HarnessOAuth.access_token(ctx.server, ctx.opts)
  end
end
