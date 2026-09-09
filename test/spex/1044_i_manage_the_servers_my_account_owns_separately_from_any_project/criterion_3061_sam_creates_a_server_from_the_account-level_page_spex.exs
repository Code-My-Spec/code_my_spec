defmodule CodeMySpecSpex.Story1044.Criterion3061Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3061 — Sam creates a server from the account-level page.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  # A minimal, in-memory Hetzner double: one datacenter offering one size, and
  # a servers list that grows on POST — enough for the provisioning form to
  # have something to offer and for the created server to show up afterward.
  # Inline rather than shared: this is the first spec to need it.
  defp stub_hetzner do
    {:ok, state} = Agent.start_link(fn -> [] end)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      reply(conn, conn.method, conn.request_path, decode(body), state)
    end

    Req.Test.stub(Hetzner, plug)
  end

  defp reply(conn, "GET", "/v1/datacenters", _payload, _state) do
    json(conn, %{
      "datacenters" => [
        %{
          "name" => "fsn1-dc14",
          "location" => %{"name" => "fsn1", "city" => "Falkenstein"},
          "server_types" => %{"available" => [1]}
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/server_types", _payload, _state) do
    json(conn, %{
      "server_types" => [
        %{
          "id" => 1,
          "name" => "cax11",
          "cores" => 2,
          "memory" => 4,
          "disk" => 40,
          "architecture" => "arm",
          "deprecated" => false,
          "prices" => [%{"location" => "fsn1", "price_hourly" => %{"gross" => "0.0112"}}]
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/servers", _payload, state) do
    json(conn, %{"servers" => Agent.get(state, & &1)})
  end

  defp reply(conn, "GET", "/v1/firewalls", _payload, _state), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys", _payload, _state), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks", _payload, _state), do: json(conn, %{"networks" => []})

  defp reply(conn, "POST", "/v1/servers", payload, state) do
    server = %{
      "id" => System.unique_integer([:positive]),
      "name" => payload["name"],
      "status" => "running",
      "server_type" => %{"name" => payload["server_type"]},
      "location" => %{"name" => "fsn1"},
      "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}}
    }

    Agent.update(state, &[server | &1])
    json(conn, %{"server" => server})
  end

  defp reply(conn, "POST", "/v1/ssh_keys", _payload, _state) do
    json(conn, %{"ssh_key" => %{"id" => 1, "fingerprint" => "aa:bb"}})
  end

  defp reply(conn, _method, _path, payload, _state) do
    json(conn, %{"network" => %{"id" => 1, "name" => payload["name"]}})
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end

  defp decode(""), do: %{}
  defp decode(body), do: Jason.decode!(body)

  spex "Sam provisions a new server from the account-level page" do
    scenario "the chosen size and location are created and linked" do
      given_ "Hetzner is connected and offers exactly one buildable size", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)
        stub_hetzner()
        {:ok, context}
      end

      when_ "Sam visits the account-level servers page", context do
        {:ok, servers_live, _html} = live(context.conn, "/app/servers")
        {:ok, Map.put(context, :servers_live, servers_live)}
      end

      when_ "he checks the cost of the one size on offer", context do
        context.servers_live
        |> element("[data-test='provision-form']")
        |> render_submit(%{"server" => %{"location" => "fsn1", "size" => "cax11"}})

        {:ok, context}
      end

      when_ "he confirms the quoted cost", context do
        context.servers_live
        |> element("[data-test='provision-confirm']")
        |> render_click()

        {:ok, context}
      end

      then_ "the new server appears on the page, already linked", context do
        assert has_element?(context.servers_live, "[data-test='server'][data-linked='true']"),
               "expected the newly created server to render linked"

        refute has_element?(context.servers_live, "[data-test='no-servers']"),
               "the page must no longer read as having no servers"

        {:ok, context}
      end
    end
  end
end
