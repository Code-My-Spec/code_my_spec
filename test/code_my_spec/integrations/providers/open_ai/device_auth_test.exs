defmodule CodeMySpec.Integrations.Providers.OpenAI.DeviceAuthTest do
  @moduledoc """
  Pi's ChatGPT login, reproduced, asserted against the shapes Pi itself parses.

  The browser half of Pi's login is not reproducible here and the moduledoc on
  the client says why: its `redirect_uri` is a fixed `localhost:1455`, registered
  against the client, so a hosted callback is refused before anyone sees a
  consent screen. The device half needs no redirect of ours, which is what makes
  it the one that works from a container.

  The pending case gets its own tests because it is the one an implementation
  gets wrong quietly. OpenAI answers 403 or 404 while it waits for the human,
  and a poller that reads those as failure abandons every login before the
  person has finished typing the code — a bug that looks like the provider being
  flaky rather than like a mistake.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Integrations.Providers.OpenAI.DeviceAuth

  defp stub(fun), do: Req.Test.stub(DeviceAuth, fun)

  describe "requesting a code the human can type" do
    test "returns what to show them and how often to poll" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "device_auth_id" => "dev-123",
          "user_code" => "ABCD-EFGH",
          "interval" => 5
        })
      end)

      assert {:ok, device} = DeviceAuth.request_device_code()
      assert device.device_auth_id == "dev-123"
      assert device.user_code == "ABCD-EFGH"
      assert device.interval_seconds == 5
      assert device.verification_uri == "https://auth.openai.com/codex/device"
    end

    test "an interval sent as a string is still a number" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "device_auth_id" => "dev-123",
          "user_code" => "ABCD-EFGH",
          "interval" => "7"
        })
      end)

      assert {:ok, %{interval_seconds: 7}} = DeviceAuth.request_device_code()
    end

    test "a response missing the code is refused rather than half-accepted" do
      stub(fn conn -> Req.Test.json(conn, %{"device_auth_id" => "dev-123"}) end)

      assert {:error, {:missing_field, "user_code", _}} = DeviceAuth.request_device_code()
    end
  end

  describe "polling while the human is still typing" do
    test "403 is pending, not failure" do
      stub(fn conn -> conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{}) end)

      assert {:error, :pending} = DeviceAuth.poll(device())
    end

    test "404 is pending too" do
      stub(fn conn -> conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{}) end)

      assert {:error, :pending} = DeviceAuth.poll(device())
    end

    test "and so is the error code OpenAI names it with" do
      stub(fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{"error" => %{"code" => "deviceauth_authorization_pending"}})
      end)

      assert {:error, :pending} = DeviceAuth.poll(device())
    end

    test "a real failure is not mistaken for pending" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "expired_token"})
      end)

      assert {:error, {:device_auth_failed, _}} = DeviceAuth.poll(device())
    end
  end

  describe "when the human has finished" do
    test "the authorization code and OpenAI's own verifier come back" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "authorization_code" => "auth-code-abc",
          "code_verifier" => "verifier-xyz"
        })
      end)

      assert {:ok, grant} = DeviceAuth.poll(device())
      assert grant.authorization_code == "auth-code-abc"

      assert grant.code_verifier == "verifier-xyz",
             "the verifier is minted at OpenAI's end and handed back, which is why " <>
               "nothing here generates one. Dropping it makes the exchange fail with " <>
               "an invalid_grant that reads like a bad code."
    end

    test "and exchange trades them for the tokens an agent runs on" do
      stub(fn conn ->
        Req.Test.json(conn, %{
          "access_token" => "access-abc",
          "refresh_token" => "refresh-abc",
          "expires_in" => 3600
        })
      end)

      assert {:ok, tokens} =
               DeviceAuth.exchange(%{
                 authorization_code: "auth-code-abc",
                 code_verifier: "verifier-xyz"
               })

      assert tokens["access_token"] == "access-abc"

      assert tokens["refresh_token"] == "refresh-abc",
             "OpenAI rotates the refresh token, so the one that comes back is the " <>
               "only one that will work next time. Recorded from a real refresh: the " <>
               "request carried rt.1.AACP… and the response returned rt.1.AAD9…"
    end

    test "a refused exchange says so rather than returning an empty grant" do
      stub(fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      assert {:error, {:token_exchange_failed, 400, _}} =
               DeviceAuth.exchange(%{authorization_code: "bad", code_verifier: "bad"})
    end
  end

  defp device do
    %{
      device_auth_id: "dev-123",
      user_code: "ABCD-EFGH",
      interval_seconds: 5,
      verification_uri: "https://auth.openai.com/codex/device"
    }
  end
end
