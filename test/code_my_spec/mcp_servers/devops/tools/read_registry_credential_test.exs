defmodule CodeMySpec.McpServers.Devops.Tools.ReadRegistryCredentialTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Devops.Tools.ReadRegistryCredential
  alias CodeMySpec.ProjectSecrets
  alias CodeMySpec.Provisioning.EnvironmentRepository
  alias CodeMySpec.Provisioning.Hetzner
  alias CodeMySpec.Provisioning.Registry
  alias CodeMySpec.Servers.Server

  setup do
    scope = full_scope_fixture()
    {:ok, _} = ProjectSecrets.put_value(scope, "hetzner_api_token", "test-token")
    %{scope: scope, project: scope.active_project}
  end

  describe "execute/2" do
    # The whole point: :server already minted and stored this credential in
    # ProjectSecrets before it ever reaches the local-filesystem write a
    # project with no checkout on this side cannot complete — this reads the
    # real values back rather than a caller having to guess or re-derive them.
    # The registry address is resolved per environment (Steps.registry_address/3),
    # never the project-wide "localhost:5000" placeholder — a shared box can
    # put two environments on two different servers with two different real
    # addresses.
    test "returns the environment's real registry address, image and credential", %{
      scope: scope
    } do
      record_server_and_network(self())
      link_environment(scope, "prod", "cms-app")

      {:ok, image} = Registry.image(scope, registry_host: "10.0.0.2:5000")
      {:ok, credential} = Registry.credential(scope)

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ReadRegistryCredential.execute(%{environment: "prod"}, frame)

      assert response.isError == false
      text = response_text(response)
      assert text =~ "registry: 10.0.0.2:5000"
      assert text =~ "image: #{image}"
      assert text =~ "username: #{credential.username}"
      assert text =~ "password: #{credential.password}"
    end

    test "reports not provisioned when the environment has no linked server", %{scope: scope} do
      record_server_and_network(self())

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               ReadRegistryCredential.execute(%{environment: "prod"}, frame)

      assert response.isError == true
      assert response_text(response) =~ "no server with a private network yet"
    end
  end

  defp link_environment(scope, environment, name) do
    {:ok, _} = Server.link(scope, %{name: name})
    linked = Server.get_linked(scope, name)
    {:ok, _} = EnvironmentRepository.put(scope, environment, %{server_id: linked.id})
  end

  defp record_server_and_network(owner) do
    servers = [
      %{
        "id" => 401,
        "name" => "cms-app",
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "1.2.3.4"}},
        "private_net" => [%{"network" => 77, "ip" => "10.0.0.2"}]
      }
    ]

    network = %{
      "id" => 77,
      "name" => "cms-app",
      "ip_range" => "10.0.0.0/16",
      "subnets" => [%{"network_zone" => "eu-central", "ip_range" => "10.0.0.0/24"}]
    }

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      payload = decode(body)
      send(owner, {:ran, conn.method, conn.request_path, payload})
      reply(conn, conn.method, conn.request_path, servers, network)
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp reply(conn, "GET", "/v1/servers", servers, _network),
    do: json(conn, %{"servers" => servers})

  defp reply(conn, "GET", "/v1/firewalls", _servers, _network),
    do: json(conn, %{"firewalls" => []})

  defp reply(conn, "GET", "/v1/ssh_keys", _servers, _network),
    do: json(conn, %{"ssh_keys" => []})

  defp reply(conn, "GET", "/v1/networks", _servers, network),
    do: json(conn, %{"networks" => [network]})

  defp decode(""), do: %{}
  defp decode(body), do: Jason.decode!(body)

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
