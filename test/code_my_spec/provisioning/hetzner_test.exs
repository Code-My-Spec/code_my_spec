defmodule CodeMySpec.Provisioning.HetznerTest do
  @moduledoc """
  The HTTP paths are stubbed here. The client was separately exercised against
  the live Hetzner API — a real firewall and server created, idempotence
  confirmed, both destroyed — which is where the `cx22`-is-deprecated and
  arm-capacity findings came from. These tests pin the behaviour that survived
  that, so a regression shows up without needing to spend money again.
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Users.Scope

  @scope %Scope{}

  defp stub(fun) do
    Application.put_env(:code_my_spec, Hetzner, api_token: "test-token", plug: fun)
    on_exit(fn -> Application.delete_env(:code_my_spec, Hetzner) end)
  end

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  describe "the firewall policy" do
    # Criterion 8004: the database port must never answer from the internet.
    # The cheapest way to keep that true is to have no code path that opens
    # it, so the public rule set is a fixed list rather than a parameter.
    test "opens only the web ports to the internet" do
      assert Hetzner.public_ports() == ["80", "443"]

      ports = Enum.map(Hetzner.default_firewall_rules(), & &1.port)
      assert ports == ["80", "443"]
    end

    test "every default rule is inbound from anywhere" do
      for rule <- Hetzner.default_firewall_rules() do
        assert rule.direction == "in"
        assert "0.0.0.0/0" in rule.source_ips
      end
    end

    test "the database port is absent, not merely unlisted" do
      refute "5432" in Enum.map(Hetzner.default_firewall_rules(), & &1.port)
      refute "22" in Enum.map(Hetzner.default_firewall_rules(), & &1.port)
    end
  end

  describe "architecture defaults" do
    # The user runs x86 in the US for production and arm in Europe because it
    # is cheaper. Both must be reachable without hand-passing a server type.
    test "arm and x86 name different types and regions" do
      arm = Hetzner.defaults_for(:arm)
      x86 = Hetzner.defaults_for(:x86)

      assert arm.server_type != x86.server_type
      assert arm.location != x86.location
    end

    # The whole cx line is retired — the live API answers "server type 104 is
    # deprecated" for cx22 and no cx type appears in /server_types. A default
    # that reintroduces one produces a create that always fails.
    test "no default uses a retired cx server type" do
      for arch <- [:arm, :x86] do
        refute Hetzner.defaults_for(arch).server_type =~ ~r/^cx/
      end
    end
  end

  describe "create_server/3" do
    test "sends the arch's defaults" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = Jason.decode!(body)

        assert payload["server_type"] == Hetzner.defaults_for(:arm).server_type
        assert payload["location"] == Hetzner.defaults_for(:arm).location

        json(conn, 201, %{"server" => %{"id" => 1, "name" => payload["name"]}})
      end)

      assert {:ok, %{"server" => %{"id" => 1}}} = Hetzner.create_server(@scope, "box")
    end

    test "an explicit option beats the arch default" do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["location"] == "hel1"
        json(conn, 201, %{"server" => %{"id" => 1}})
      end)

      assert {:ok, _} = Hetzner.create_server(@scope, "box", location: "hel1")
    end

    test "surfaces the provider's own error rather than a generic one" do
      stub(fn conn ->
        json(conn, 400, %{"error" => %{"code" => "invalid_input", "message" => "server type 104 is deprecated"}})
      end)

      assert {:error, {:hetzner_error, 400, body}} = Hetzner.create_server(@scope, "box")
      assert body["error"]["message"] =~ "deprecated"
    end
  end

  describe "ensure_server/3 — idempotence" do
    # Criterion 7965: running a step twice leaves one of everything.
    test "reuses an existing server instead of creating a second" do
      stub(fn
        %{method: "GET"} = conn ->
          json(conn, 200, %{"servers" => [%{"id" => 7, "name" => "box"}]})

        %{method: "POST"} = conn ->
          flunk("ensure_server created a second server when one already existed")
          conn
      end)

      assert {:ok, %{"id" => 7}} = Hetzner.ensure_server(@scope, "box")
    end

    test "creates when absent" do
      stub(fn
        %{method: "GET"} = conn -> json(conn, 200, %{"servers" => []})
        %{method: "POST"} = conn -> json(conn, 201, %{"server" => %{"id" => 9, "name" => "box"}})
      end)

      assert {:ok, %{"id" => 9}} = Hetzner.ensure_server(@scope, "box")
    end
  end

  describe "find_server/2" do
    # Criterion 7970 checks state against the provider, and 7964 requires a
    # resource deleted behind setup's back to be rebuilt rather than skipped.
    # Both rest on absence being reported as absence.
    test "a server deleted behind setup's back reads as not_found" do
      stub(fn conn -> json(conn, 200, %{"servers" => [%{"id" => 1, "name" => "other"}]}) end)

      assert {:error, :not_found} = Hetzner.find_server(@scope, "box")
    end
  end

  describe "credentials" do
    test "an unconfigured token is a named error, not a crash" do
      Application.delete_env(:code_my_spec, Hetzner)

      assert {:error, :hetzner_not_configured} = Hetzner.list_servers(@scope)
    end

    test "credential_valid? is false when the provider rejects the token" do
      stub(fn conn -> json(conn, 401, %{"error" => %{"code" => "unauthorized"}}) end)

      refute Hetzner.credential_valid?(@scope)
    end

    test "credential_valid? is true when the account is reachable" do
      stub(fn conn -> json(conn, 200, %{"servers" => []}) end)

      assert Hetzner.credential_valid?(@scope)
    end
  end
end
