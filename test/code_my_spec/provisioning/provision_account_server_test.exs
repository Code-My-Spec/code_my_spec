defmodule CodeMySpec.Provisioning.ProvisionAccountServerTest do
  @moduledoc """
  `Steps.provision_account_server/3` — the account-level half of the hard
  line: bring up a server plus its shared registry and database containers,
  never a project's own concern (`environment_servers_test.exs` covers that
  half refusing to do this itself).

  An explicit `:run` bypasses `Remote.ssh_runner/2`'s real SSH the same way
  `environment_servers_test.exs` does — the claim under test is what this
  function does with a box, not whether it can open a socket to one.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AccountSecrets
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Steps
  alias CodeMySpec.Servers.Server

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_access_key_id", "test-key-id")
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_s3_secret_access_key", "test-secret")

    # Pre-seeded rather than left for `Servers.access_key/1` to generate: its
    # fallback shells out to a real `ssh-keygen`, and under this suite's own
    # parallel load that occasionally lost a race against something else on
    # the account secrets table, once in several dozen runs, isolated
    # nowhere else. Nothing here ever opens a real connection with either
    # key — every test already routes SSH through `succeeding_run/0`.
    {:ok, _} = AccountSecrets.put_value(scope, "server_ssh_public_key", "ssh-ed25519 AAAAfake test-fixture")
    {:ok, _} = AccountSecrets.put_value(scope, "server_ssh_private_key", "-----BEGIN FAKE KEY-----\nfixture\n-----END FAKE KEY-----\n")

    {:ok, scope: scope}
  end

  test "adopts an existing box and brings its registry and database up", %{scope: scope} do
    record_requests(self(), existing: true)

    opts = [
      run: succeeding_run(),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, server} = Steps.provision_account_server(scope, "acme-box", opts)
    assert server["name"] == "acme-box"

    assert_received {:ran, "GET", "/v1/servers"}
    refute_received {:ran, "POST", "/v1/servers"}
    refute_received {:ran, "POST", "/v1/networks"},
                     "expected the box's own already-attached network to be adopted, not a new one created"
  end

  test "creates a new box when the provider has no server by that name", %{scope: scope} do
    record_requests(self(), existing: false)

    opts = [
      run: succeeding_run(),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, server} = Steps.provision_account_server(scope, "fresh-box", opts)
    assert server["name"] == "fresh-box"

    assert_received {:ran, "POST", "/v1/servers"}
    assert_received {:ran, "POST", "/v1/networks"},
                     "expected a network to be created for a genuinely new box"
  end

  # The account, not just this one call, is what a network's range must not
  # collide with — two other zones already hold index 0 and 1 (10.0.0.0/16,
  # 10.1.0.0/16) from boxes this test never touches, so a fresh box's own
  # zone has to land on index 2 or later. Reproduces the shape that mattered
  # live: an account's *other* networks, not only the servers in front of
  # this particular call, are what `networks_overlap` checks against.
  test "a new box's network avoids ranges the account's other networks already hold", %{
    scope: scope
  } do
    test_pid = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(test_pid, {:ran, conn.method, conn.request_path, payload})
      collision_reply(conn, conn.method, conn.request_path, payload)
    end

    Req.Test.stub(Hetzner, plug)

    opts = [
      run: succeeding_run(),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:ok, _server} = Steps.provision_account_server(scope, "third-box", opts)

    assert_receive {:ran, "POST", "/v1/networks", payload}
    assert payload["ip_range"] == "10.2.0.0/16", "expected the next free index, got #{inspect(payload)}"
  end

  defp collision_reply(conn, "GET", "/v1/servers", _payload), do: json(conn, %{"servers" => []})
  defp collision_reply(conn, "GET", "/v1/firewalls", _payload), do: json(conn, %{"firewalls" => []})
  defp collision_reply(conn, "GET", "/v1/ssh_keys", _payload), do: json(conn, %{"ssh_keys" => []})

  defp collision_reply(conn, "GET", "/v1/networks", _payload) do
    json(conn, %{
      "networks" => [
        %{"id" => 90, "name" => "one", "ip_range" => "10.0.0.0/16", "subnets" => []},
        %{"id" => 91, "name" => "two", "ip_range" => "10.1.0.0/16", "subnets" => []}
      ]
    })
  end

  defp collision_reply(conn, "POST", "/v1/ssh_keys", _payload),
    do: json(conn, %{"ssh_key" => %{"id" => 1, "fingerprint" => "aa:bb"}})

  defp collision_reply(conn, "POST", "/v1/servers", payload) do
    json(conn, %{
      "server" => %{
        "id" => System.unique_integer([:positive]),
        "name" => payload["name"],
        "status" => "running",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}}
      }
    })
  end

  defp collision_reply(conn, _method, _path, payload),
    do: json(conn, %{"network" => %{"id" => 92, "name" => payload["name"]}})

  test "refuses when the box has no address to reach it at", %{scope: scope} do
    record_requests(self(), existing: false, no_address: true)

    opts = [
      run: succeeding_run(),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:error, "the server has no address yet"} =
             Steps.provision_account_server(scope, "addressless-box", opts)
  end

  test "surfaces a provider error rather than swallowing it", %{scope: scope} do
    record_requests(self(), refuse_create: true)

    opts = [
      run: succeeding_run(),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    assert {:error, reason} = Steps.provision_account_server(scope, "sold-out-box", opts)
    # Both architectures 412 on this stub, so `create_server/3` reports it as
    # what it actually is — a capacity shortage — rather than the raw status.
    assert reason =~ "capacity shortage"
  end

  test "does not require the server to already be linked", %{scope: scope} do
    record_requests(self(), existing: false)

    opts = [
      run: succeeding_run(),
      credentials: [access_key_id: "unused", secret_access_key: "unused"]
    ]

    refute Server.get_linked(scope, "never-linked-box")
    assert {:ok, _server} = Steps.provision_account_server(scope, "never-linked-box", opts)

    # provision_account_server/3 only brings the box and containers up — it is
    # ProvisionAccountServer (the MCP tool) that links, same split as
    # Servers.provision/2 vs. Server.link/2 on the human path.
    refute Server.get_linked(scope, "never-linked-box")
  end

  defp succeeding_run, do: fn [_command] -> {"", 0} end

  defp record_requests(owner, opts) do
    existing = Keyword.get(opts, :existing, false)
    no_address = Keyword.get(opts, :no_address, false)
    refuse_create = Keyword.get(opts, :refuse_create, false)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = if body == "", do: %{}, else: Jason.decode!(body)
      send(owner, {:ran, conn.method, conn.request_path})
      reply(conn, conn.method, conn.request_path, payload, existing, no_address, refuse_create)
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp reply(conn, "GET", "/v1/servers", _payload, true, no_address, _refuse) do
    ip = if no_address, do: nil, else: "203.0.113.10"

    json(conn, %{
      "servers" => [
        %{
          "id" => 1,
          "name" => "acme-box",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => ip}},
          "private_net" => [%{"network" => 42, "ip" => "10.0.0.5"}]
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/servers", _payload, false, _no_address, _refuse) do
    json(conn, %{"servers" => []})
  end

  defp reply(conn, "GET", "/v1/firewalls", _payload, _existing, _no_address, _refuse),
    do: json(conn, %{"firewalls" => []})

  defp reply(conn, "GET", "/v1/ssh_keys", _payload, _existing, _no_address, _refuse),
    do: json(conn, %{"ssh_keys" => []})

  defp reply(conn, "GET", "/v1/networks", _payload, true, _no_address, _refuse) do
    json(conn, %{
      "networks" => [
        %{
          "id" => 42,
          "name" => "acme",
          "ip_range" => "10.0.0.0/16",
          "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.0.0.0/24"}]
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/networks", _payload, false, _no_address, _refuse),
    do: json(conn, %{"networks" => []})

  defp reply(conn, "POST", "/v1/ssh_keys", _payload, _existing, _no_address, _refuse),
    do: json(conn, %{"ssh_key" => %{"id" => 1, "fingerprint" => "aa:bb"}})

  defp reply(conn, "POST", "/v1/servers", _payload, _existing, no_address, true) do
    _ = no_address

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(
      412,
      Jason.encode!(%{"error" => %{"code" => "resource_unavailable", "message" => "error during placement"}})
    )
  end

  defp reply(conn, "POST", "/v1/servers", payload, _existing, no_address, false) do
    ip = if no_address, do: nil, else: "203.0.113.10"

    json(conn, %{
      "server" => %{
        "id" => System.unique_integer([:positive]),
        "name" => payload["name"],
        "status" => "running",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => ip}}
      }
    })
  end

  defp reply(conn, _method, _path, payload, _existing, _no_address, _refuse) do
    json(conn, %{"network" => %{"id" => 1, "name" => payload["name"]}})
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end
end
