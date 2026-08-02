defmodule CodeMySpec.Provisioning.CloudflareTest do
  @moduledoc """
  Read paths were separately verified against the live Cloudflare API — zones,
  account-id extraction, and the confirmation gate. The write and failure
  paths are stubbed here because exercising them for real means buying a
  domain.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.Cloudflare
  alias CodeMySpec.Users.Scope

  @scope %Scope{}
  @account "6477547f586ec90db2c2a0081dcd98bd"

  defp stub(fun) do
    Application.put_env(:code_my_spec, Cloudflare, api_token: "test-token", plug: fun)
    on_exit(fn -> Application.delete_env(:code_my_spec, Cloudflare) end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp ok(result), do: %{"success" => true, "errors" => [], "result" => result}

  defp fail(message),
    do: %{"success" => false, "errors" => [%{"message" => message}], "result" => nil}

  defp zones_payload, do: ok([%{"id" => "z1", "name" => "example.com", "account" => %{"id" => @account}}])

  describe "the confirmation gate" do
    # Criterion 7990. Registrations are non-refundable, so this must hold even
    # if a caller forgets — hence the guard living in the context rather than
    # only in the LiveView.
    test "refuses to register without an explicit confirmation, and makes no request" do
      stub(fn conn ->
        flunk("register_domain issued a request without confirmation: #{conn.request_path}")
        conn
      end)

      assert {:error, :confirmation_required} = Cloudflare.register_domain(@scope, "sams.com")
      assert {:error, :confirmation_required} =
               Cloudflare.register_domain(@scope, "sams.com", confirmed: false)
    end

    test "registers once confirmed" do
      stub(fn
        # Registration resolves the account first, and that now goes to
        # /accounts before falling back to the zone list.
        %{method: "GET", request_path: "/client/v4/accounts"} = conn ->
          json(conn, 200, ok([%{"id" => @account}]))

        %{method: "GET", request_path: "/client/v4/zones"} = conn ->
          json(conn, 200, zones_payload())

        %{method: "POST"} = conn ->
          json(conn, 200, ok(%{"name" => "sams.com", "status" => "pendingRegistration"}))
      end)

      assert {:ok, %{"result" => %{"name" => "sams.com"}}} =
               Cloudflare.register_domain(@scope, "sams.com", confirmed: true)
    end
  end

  describe "a registration Cloudflare refuses" do
    # Criteria 7993 and 7994: the API's limits become a detour, and the reason
    # is named rather than guessed at.
    test "an unsupported TLD pauses with a dashboard errand rather than erroring" do
      assert {:paused, message} =
               Cloudflare.classify_registration_error(
                 {400, fail("This TLD is not supported by the Registrar API beta")}
               )

      assert message =~ ~r/dashboard/i
      assert message =~ ~r/adopt/i
    end

    test "a missing payment method names the reason and quotes the provider" do
      assert {:paused, message} =
               Cloudflare.classify_registration_error(
                 {400, fail("No payment method on file for this account")}
               )

      assert message =~ ~r/payment method/i
      assert message =~ ~r/billing/i
      # The provider's own words survive, so the errand is specific.
      assert message =~ "No payment method on file"
    end

    # Deliberately conservative: an unrecognised failure must NOT become a
    # pause, because a pause tells Sam to go do something and this one could
    # not say what.
    test "an unrecognised failure stays an error" do
      assert {:error, {:cloudflare_error, 500, _}} =
               Cloudflare.classify_registration_error({500, fail("internal server error")})
    end
  end

  describe "ensure_domain/3" do
    # Criteria 8052 and 7991 at once: owning it already is an ordinary way in,
    # and a retried step does not buy a second domain.
    test "adopts a domain the account already holds, without registering" do
      stub(fn
        %{method: "GET", request_path: "/client/v4/zones"} = conn ->
          json(conn, 200, zones_payload())

        %{method: "GET"} = conn ->
          json(conn, 200, ok([%{"name" => "sams.com"}]))

        %{method: "POST"} = conn ->
          flunk("ensure_domain registered a domain the account already owned")
          conn
      end)

      assert {:ok, :adopted} = Cloudflare.ensure_domain(@scope, "sams.com", confirmed: true)
    end

    test "still requires confirmation when the domain is absent" do
      stub(fn
        %{method: "GET", request_path: "/client/v4/zones"} = conn ->
          json(conn, 200, zones_payload())

        %{method: "GET"} = conn ->
          json(conn, 200, ok([]))

        %{method: "POST"} = conn ->
          flunk("registered without confirmation")
          conn
      end)

      assert {:error, :confirmation_required} = Cloudflare.ensure_domain(@scope, "sams.com")
    end
  end

  describe "DNS records" do
    # Criterion 7996: a proxied record terminates HTTP-01 at Cloudflare's edge,
    # so issuance hangs while the dashboard looks correct.
    test "are unproxied by default" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["proxied"] == false
        json(conn, 200, ok(%{"id" => "r1"}))
      end)

      assert {:ok, _} = Cloudflare.create_dns_record(@scope, "z1", "app.example.com", "1.2.3.4")
    end

    test "ensure_dns_record leaves an already-correct record alone" do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, ok([%{"id" => "r1", "name" => "app.example.com", "type" => "A", "content" => "1.2.3.4"}]))

        conn ->
          flunk("ensure_dns_record wrote when the record was already correct")
          conn
      end)

      assert {:ok, %{"result" => %{"id" => "r1"}}} =
               Cloudflare.ensure_dns_record(@scope, "z1", "app.example.com", "1.2.3.4")
    end

    # An apex record duplicated rather than updated breaks inbound mail, so
    # this is not merely untidiness.
    test "ensure_dns_record updates in place when the content differs" do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, ok([%{"id" => "r1", "name" => "example.com", "type" => "A", "content" => "9.9.9.9"}]))

        %{method: "PUT", request_path: path} = conn ->
          assert path =~ "/dns_records/r1"
          json(conn, 200, ok(%{"id" => "r1", "content" => "1.2.3.4"}))

        %{method: "POST"} = conn ->
          flunk("ensure_dns_record created a duplicate instead of updating")
          conn
      end)

      assert {:ok, _} = Cloudflare.ensure_dns_record(@scope, "z1", "example.com", "1.2.3.4")
    end
  end

  describe "account_id/1" do
    # `GET /accounts` is the primary path. The stub is per-path on purpose: a
    # blanket stub answered /accounts with the zone list, and the first zone's
    # id was read as an account id — a green test asserting the wrong thing.
    test "reads the account from the accounts endpoint" do
      stub(fn
        %{request_path: "/client/v4/accounts"} = conn ->
          json(conn, 200, ok([%{"id" => @account, "name" => "Sam"}]))

        conn ->
          flunk("account_id went to #{conn.request_path} before trying /accounts")
      end)

      assert {:ok, @account} = Cloudflare.account_id(@scope)
    end

    # A grant scoped to one zone rather than the whole account is a
    # configuration somebody has, and it can still self-serve.
    test "falls back to the zone list when /accounts shows nothing" do
      stub(fn
        %{request_path: "/client/v4/accounts"} = conn -> json(conn, 200, ok([]))
        conn -> json(conn, 200, zones_payload())
      end)

      assert {:ok, @account} = Cloudflare.account_id(@scope)
    end

    # This used to be the *only* path, and it failed for precisely the case
    # setup exists to serve: a Cloudflare account with no zones in it yet.
    test "says so when neither path exposes an account" do
      stub(fn conn -> json(conn, 200, ok([])) end)

      assert {:error, :no_account_visible} = Cloudflare.account_id(@scope)
    end
  end

  describe "error handling" do
    # Cloudflare answers 200 with success:false for some failures, so status
    # alone would report a failure as success.
    test "a 200 carrying success:false is an error" do
      stub(fn conn -> json(conn, 200, fail("nope")) end)

      assert {:error, {:cloudflare_error, 200, _}} = Cloudflare.list_zones(@scope)
    end

    test "an unconfigured credential is a named error, not a crash" do
      Application.delete_env(:code_my_spec, Cloudflare)

      assert {:error, :cloudflare_not_connected} = Cloudflare.list_zones(@scope)
    end
  end
end
