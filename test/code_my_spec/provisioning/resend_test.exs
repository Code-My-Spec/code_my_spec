defmodule CodeMySpec.Provisioning.ResendTest do
  @moduledoc """
  The record fixtures below are the real shape returned by Resend for a
  verified domain with inbound configured — captured from the live API, not
  invented. That distinction matters: an earlier draft of this module assumed
  Resend never asks for an apex record, and a hand-written fixture would have
  agreed with the assumption instead of contradicting it.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.Resend
  alias CodeMySpec.Users.Scope

  doctest Resend, only: [sending_domain: 2]

  @scope %Scope{}
  @domain "example.com"

  # Exactly what the live API returns: three sending records, plus an apex MX
  # that exists only because Resend Inbound is configured.
  @live_records [
    %{"name" => "resend._domainkey", "type" => "TXT", "status" => "verified"},
    %{"name" => "send", "type" => "MX", "status" => "verified"},
    %{"name" => "send", "type" => "TXT", "status" => "verified"},
    %{"name" => "", "type" => "MX", "status" => "verified"}
  ]

  defp stub(fun) do
    Application.put_env(:code_my_spec, Resend, api_key: "test-key", plug: fun)
    on_exit(fn -> Application.delete_env(:code_my_spec, Resend) end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "one sending domain per environment" do
    # Criterion 8056: test mail must never be mistakable for real mail, and a
    # UAT reputation problem must not touch production's domain.
    test "production sends from the bare domain, others from a subdomain" do
      assert Resend.sending_domain(@domain, "prod") == "example.com"
      assert Resend.sending_domain(@domain, "production") == "example.com"
      assert Resend.sending_domain(@domain, "uat") == "uat.example.com"
    end

    test "the environments are distinct, and UAT is a subdomain of production" do
      prod = Resend.sending_domain(@domain, "prod")
      uat = Resend.sending_domain(@domain, "uat")

      refute prod == uat
      assert String.ends_with?(uat, prod)
    end
  end

  describe "the apex-versus-send split" do
    # Criterion 8029. The apex MX belongs to inbound (story 974); the sending
    # setup must leave it alone. Confirmed against the live record set.
    test "sending records exclude the apex" do
      sending = Resend.sending_records(@live_records, @domain)

      assert length(sending) == 3
      assert Enum.map(sending, & &1["name"]) == ["resend._domainkey", "send", "send"]
      refute Enum.any?(sending, &(&1["name"] == ""))
    end

    test "inbound records are exactly the apex MX" do
      assert [%{"name" => "", "type" => "MX"}] = Resend.inbound_records(@live_records, @domain)
    end

    test "the outbound half is apex-free" do
      assert Resend.sending_avoids_apex?(@live_records, @domain)
    end

    # The apex can be spelled three ways depending on who is rendering it.
    # Missing one would classify an inbound record as a sending record and
    # hand it to a step that may rewrite it.
    test "recognises every spelling of the apex" do
      for apex <- ["", "@", @domain] do
        records = [%{"name" => apex, "type" => "MX"}]

        assert Resend.inbound_records(records, @domain) == records
        assert Resend.sending_records(records, @domain) == []
      end
    end

    test "a domain with no inbound configured has no inbound records" do
      sending_only = Enum.reject(@live_records, &(&1["name"] == ""))

      assert Resend.inbound_records(sending_only, @domain) == []
      assert Resend.sending_avoids_apex?(sending_only, @domain)
    end
  end

  describe "faulted_records/1" do
    # Criterion 8027: "verification timed out" leaves Sam diffing three
    # records by eye. Naming the record turns that into a fix.
    test "names only the records the provider is unhappy with" do
      domain = %{
        "records" => [
          %{"name" => "resend._domainkey", "status" => "not_started"},
          %{"name" => "send", "status" => "verified"}
        ]
      }

      assert [%{"name" => "resend._domainkey"}] = Resend.faulted_records(domain)
    end

    test "is empty for a fully verified domain" do
      assert Resend.faulted_records(%{"records" => @live_records}) == []
    end
  end

  describe "poll_until_verified/3" do
    # Criterion 8026: publishing records and declaring victory leaves an
    # unverified domain and mail that 403s on the first send.
    test "polls until verified and reports how many attempts it took" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(fn conn ->
        n = Agent.get_and_update(counter, &{&1 + 1, &1 + 1})
        status = if n >= 3, do: "verified", else: "pending"
        json(conn, 200, %{"id" => "d1", "status" => status, "records" => @live_records})
      end)

      assert {:ok, %{attempts: 3, verified_at: %DateTime{}}} =
               Resend.poll_until_verified(@scope, "d1", interval_ms: 0, sleep: fn _ -> :ok end)
    end

    # Criterion 8027 again, from the other side: giving up must name the
    # record, not just the timeout.
    test "gives up naming the faulted record rather than reporting a timeout" do
      stub(fn conn ->
        json(conn, 200, %{
          "id" => "d1",
          "status" => "pending",
          "records" => [
            %{"name" => "resend._domainkey", "type" => "TXT", "status" => "not_started"},
            %{"name" => "send", "type" => "MX", "status" => "verified"}
          ]
        })
      end)

      assert {:error, {:unverified, [faulted]}} =
               Resend.poll_until_verified(@scope, "d1", attempts: 2, sleep: fn _ -> :ok end)

      assert faulted["name"] =~ "_domainkey"
    end

    test "an already-verified domain settles on the first attempt" do
      stub(fn conn ->
        json(conn, 200, %{"id" => "d1", "status" => "verified", "records" => @live_records})
      end)

      assert {:ok, %{attempts: 1}} =
               Resend.poll_until_verified(@scope, "d1", sleep: fn _ -> :ok end)
    end
  end

  describe "ensure_domain/3" do
    test "reuses an existing domain rather than registering a duplicate" do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"data" => [%{"id" => "d1", "name" => "uat.example.com"}]})

        %{method: "POST"} = conn ->
          flunk("ensure_domain registered a domain that already existed")
          conn
      end)

      assert {:ok, %{"id" => "d1"}} = Resend.ensure_domain(@scope, "uat.example.com")
    end

    test "registers when absent" do
      stub(fn
        %{method: "GET"} = conn -> json(conn, 200, %{"data" => []})
        %{method: "POST"} = conn -> json(conn, 201, %{"id" => "d2", "name" => "uat.example.com"})
      end)

      assert {:ok, %{"id" => "d2"}} = Resend.ensure_domain(@scope, "uat.example.com")
    end
  end

  describe "credentials" do
    test "an unconfigured key is a named error, not a crash" do
      Application.delete_env(:code_my_spec, Resend)

      assert {:error, :resend_not_connected} = Resend.list_domains(@scope)
    end

    test "credential_valid? is false when the provider rejects the key" do
      stub(fn conn -> json(conn, 401, %{"message" => "invalid"}) end)

      refute Resend.credential_valid?(@scope)
    end
  end
end
