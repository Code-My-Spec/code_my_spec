defmodule CodeMySpec.Provisioning.ServerRegistryVerifyTest do
  @moduledoc """
  A box with no registry must not verify satisfied.

  c1d8eaff, reproduced without a real Hetzner project: `verify(:server, …)`
  used to be satisfied once every environment had a box **and**
  `DATABASE_URL` in its encrypted env — both cheap signals a stale box can
  carry. Neither says anything about the registry, which `run(:server, …)`
  is the only thing that ever starts (`serve_one_registry/5`). A box made by
  a run that errored before reaching that point, checked out fresh with an
  old `DATABASE_URL` still in the tree (exactly the report's repro: leftover
  `envs/*.enc.env` from a previous domain), verified satisfied, `run/3` was
  skipped, and the failure surfaced two steps later at `deploy` — a bare
  connection refused that never named the registry.

  Real sops and age, the way `secrets_verify_test.exs` does it: the claim
  under test is whether the step notices a real gap, which only the real
  tools can tell the truth about.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.{Hetzner, Sops, Steps}

  @moduletag :sops

  @server_name "some-name-uat"
  @network_id 42
  @public_ip "203.0.113.9"
  @private_ip "10.0.0.5"

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")

    stub_hetzner()

    {public, _private} = key_for(scope, "uat")
    :ok = Sops.write_config(scope.environment, %{"uat" => public})
    put_secret(scope, "uat", "DATABASE_URL", "postgresql://u:p@10.0.0.5:5432/app")

    {:ok, scope: scope}
  end

  # `:ssh_key_path` bypasses `write_builder_key/2` (and the real account
  # secret it reads), the same way an injected `:run` bypasses a real SSH
  # connection — neither claim under test is "can this process open an SSH
  # session", so neither needs to be real.
  defp verify_opts(run) do
    [environments: ["uat"], ssh_key_path: "unused", run: run]
  end

  describe "the box exists and DATABASE_URL is present, but the registry never came up" do
    test "verify(:server, …) reports absent, not satisfied", ctx do
      # What a curl against a registry nothing ever started actually returns:
      # `-sf` makes curl exit non-zero on a refused connection.
      run = fn [_command] -> {"", 7} end

      assert {:ok, :absent} = Steps.verify(:server, ctx.scope, verify_opts(run)),
             "a box with no registry must not read as done — the report's exact shape"
    end

    test "the registry is the only thing missing — everything else this step checks is already true",
         ctx do
      # Proven independently of the assertion above: without this fix, both
      # the box-listing check and the DATABASE_URL check the step already had
      # pass on their own, which is what made the bug reproduce as "satisfied"
      # rather than "absent for an obvious reason".
      assert {:ok, server} = Hetzner.find_server(ctx.scope, @server_name)
      assert get_in(server, ["public_net", "ipv4", "ip"]) == @public_ip

      {:ok, private} = ProjectSecrets.fetch_value(ctx.scope, "age_private_key_uat")

      assert {:ok, missing} =
               Sops.missing_secrets(ctx.scope.environment, "uat", private, ["DATABASE_URL"])

      assert "DATABASE_URL" not in missing
    end
  end

  describe "the box exists, DATABASE_URL is present, and the registry answers" do
    test "verify(:server, …) reports satisfied", ctx do
      run = fn [command] ->
        send(self(), {:ran, command})
        {"", 0}
      end

      assert {:ok, :satisfied, resources} = Steps.verify(:server, ctx.scope, verify_opts(run))

      assert Enum.any?(resources, &(&1.kind == "server"))

      assert_received {:ran, probe}
      assert probe =~ "curl"
      assert probe =~ "http://#{@private_ip}:5000/v2/"
    end
  end

  defp key_for(scope, environment) do
    {:ok, {public, private}} = Sops.generate_key()
    {:ok, _} = ProjectSecrets.put_value(scope, "age_private_key_#{environment}", private)
    {public, private}
  end

  defp put_secret(scope, environment, key, value) do
    {:ok, private} = ProjectSecrets.fetch_value(scope, "age_private_key_#{environment}")
    :ok = Sops.put_secret(scope.environment, environment, key, value, private)
  end

  defp stub_hetzner do
    server = %{
      "id" => 1,
      "name" => @server_name,
      "location" => %{"name" => "fsn1"},
      "public_net" => %{"ipv4" => %{"ip" => @public_ip}},
      "private_net" => [%{"network" => @network_id, "ip" => @private_ip}]
    }

    network = %{"id" => @network_id, "name" => "some-name"}

    plug = fn conn -> reply(conn, conn.method, conn.request_path, server, network) end

    Req.Test.stub(Hetzner, plug)
  end

  defp reply(conn, "GET", "/v1/servers", server, _network),
    do: json(conn, %{"servers" => [server]})

  defp reply(conn, "GET", "/v1/networks", _server, network),
    do: json(conn, %{"networks" => [network]})

  defp reply(conn, "GET", "/v1/firewalls", _server, _network),
    do: json(conn, %{"firewalls" => []})

  defp reply(conn, "GET", "/v1/ssh_keys", _server, _network), do: json(conn, %{"ssh_keys" => []})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(body))
  end
end
