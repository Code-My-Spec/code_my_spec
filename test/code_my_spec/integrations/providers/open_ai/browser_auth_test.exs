defmodule CodeMySpec.Integrations.Providers.OpenAI.BrowserAuthTest do
  @moduledoc """
  Pi's ChatGPT login as Pi performs it: a browser, and a listener on 1455 to
  catch what it sends back.

  These drive the real listener rather than a stub of it. The port, the path and
  the state check are the parts that break, and none of them is exercised by
  mocking the thing that binds the port.

  Sync, because binding a fixed port is not something two tests can do at once.
  """

  use ExUnit.Case, async: false

  alias CodeMySpec.Integrations.Providers.OpenAI.BrowserAuth

  setup do
    Req.Test.stub(BrowserAuth, fn conn ->
      Req.Test.json(conn, %{
        "access_token" => "access-abc",
        "refresh_token" => "refresh-abc",
        "expires_in" => 3600
      })
    end)

    :ok
  end

  describe "the URL the browser is sent to" do
    test "carries everything OpenAI needs to issue a code" do
      {:ok, pending} = BrowserAuth.begin()
      on_exit(fn -> BrowserAuth.cancel(pending) end)

      uri = URI.parse(pending.authorize_url)
      params = URI.decode_query(uri.query)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" == "https://auth.openai.com/oauth/authorize"
      assert params["response_type"] == "code"
      assert params["redirect_uri"] == "http://localhost:1455/auth/callback"
      assert params["scope"] == "openid profile email offline_access"
      assert params["code_challenge_method"] == "S256"

      assert params["codex_cli_simplified_flow"] == "true",
             "without it the consent screen is the full Codex one rather than the " <>
               "short flow Pi's users see"

      assert params["id_token_add_organizations"] == "true",
             "this is what puts chatgpt_account_id in the id token, which every " <>
               "model call needs as a header"
    end

    test "the challenge is the S256 hash of the verifier, not the verifier" do
      {:ok, pending} = BrowserAuth.begin()
      on_exit(fn -> BrowserAuth.cancel(pending) end)

      params = pending.authorize_url |> URI.parse() |> Map.get(:query) |> URI.decode_query()
      expected = :sha256 |> :crypto.hash(pending.verifier) |> Base.url_encode64(padding: false)

      assert params["code_challenge"] == expected
      refute params["code_challenge"] == pending.verifier
    end

    test "state differs between logins" do
      {:ok, first} = BrowserAuth.begin()
      BrowserAuth.cancel(first)
      {:ok, second} = BrowserAuth.begin()
      on_exit(fn -> BrowserAuth.cancel(second) end)

      refute first.state == second.state
      refute first.verifier == second.verifier
    end
  end

  describe "the callback the browser makes" do
    test "a code with the right state completes the login" do
      {:ok, pending} = BrowserAuth.begin()

      callback(code: "the-code", state: pending.state)

      assert {:ok, tokens} = BrowserAuth.await(pending, 5_000)
      assert tokens["access_token"] == "access-abc"
      assert tokens["refresh_token"] == "refresh-abc"
    end

    test "the port is released once the login finishes" do
      {:ok, pending} = BrowserAuth.begin()
      callback(code: "the-code", state: pending.state)
      {:ok, _tokens} = BrowserAuth.await(pending, 5_000)

      assert {:ok, second} = BrowserAuth.begin(),
             "a login that finished has to give the port back, or the next one " <>
               "fails to bind and reports something unrelated to what went wrong"

      BrowserAuth.cancel(second)
    end

    test "a mismatched state is refused" do
      {:ok, pending} = BrowserAuth.begin()

      callback(code: "the-code", state: "somebody-elses-state")

      assert {:error, :state_mismatch} = BrowserAuth.await(pending, 5_000),
             "a callback carrying a state we did not issue is a cross-site request, " <>
               "and answering it hands someone else's authorization code to whoever " <>
               "is waiting"
    end

    test "OpenAI's own error is reported as OpenAI's" do
      {:ok, pending} = BrowserAuth.begin()

      callback(error: "access_denied", state: pending.state)

      assert {:error, "access_denied"} = BrowserAuth.await(pending, 5_000),
             "access_denied means the human said no. Reporting it as a transport " <>
               "failure would send them to debug their network."
    end

    test "a callback with no code at all is refused" do
      {:ok, pending} = BrowserAuth.begin()

      callback(state: pending.state)

      assert {:error, :missing_code} = BrowserAuth.await(pending, 5_000)
    end
  end

  describe "when the port is not available" do
    test "says the port is taken rather than reporting an address error" do
      {:ok, holder} = BrowserAuth.begin()
      on_exit(fn -> BrowserAuth.cancel(holder) end)

      assert {:error, :port_in_use} = BrowserAuth.begin(),
             "Pi may be mid-login on the same port. 'address in use' reads as our " <>
               "bug; naming the port says whose it is."
    end
  end

  defp callback(params) do
    query = params |> Enum.map(fn {k, v} -> {to_string(k), v} end) |> URI.encode_query()

    {:ok, _} =
      Req.get(
        url: "http://localhost:#{BrowserAuth.port()}/auth/callback?#{query}",
        retry: false
      )
  end
end
