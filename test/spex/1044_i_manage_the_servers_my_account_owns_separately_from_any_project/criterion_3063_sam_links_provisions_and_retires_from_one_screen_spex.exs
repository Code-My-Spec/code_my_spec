defmodule CodeMySpecSpex.Story1044.Criterion3063Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3063 — Sam links, provisions, and retires from one screen.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam manages a server's whole lifecycle from the account-level page" do
    scenario "linking, provisioning, and retiring all happen without leaving the page" do
      given_ "Hetzner reports one server the account has not linked yet", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)

        plug = fn conn ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path, decode(body))
        end

        Req.Test.stub(Hetzner, plug)
        {:ok, context}
      end

      when_ "Sam visits the account-level servers page", context do
        {:ok, servers_live, _html} = live(context.conn, "/app/servers")
        {:ok, Map.put(context, :servers_live, servers_live)}
      end

      when_ "he links the unlinked server without leaving the page", context do
        # Nothing is linked yet, so the unlinked section is already expanded
        # (expand_when_nothing_linked/2) — no toggle needed to see it.
        context.servers_live
        |> element("[data-test='link-server']")
        |> render_click()

        {:ok, context}
      end

      when_ "he provisions a second, brand-new server without leaving the page", context do
        context.servers_live
        |> element("[data-test='provision-form']")
        |> render_submit(%{"server" => %{"location" => "fsn1", "size" => "cax11"}})

        context.servers_live
        |> element("[data-test='provision-confirm']")
        |> render_click()

        {:ok, context}
      end

      when_ "he retires the server he just linked, without leaving the page", context do
        # Named rather than bare: the provisioned server above is linked too
        # by the time this runs, so both rows now carry a retire button.
        context.servers_live
        |> element("[data-test='retire-server'][phx-value-name='hand-built-box']")
        |> render_click()

        {:ok, context}
      end

      then_ "all three actions took effect from the one page, with no navigation away",
            context do
        assert_patched(context.servers_live, "/app/servers")

        html = render(context.servers_live)
        assert html =~ "cax11", "expected the newly provisioned server's size to render"

        {:ok, context}
      end
    end
  end

  defp decode(""), do: %{}
  defp decode(body), do: Jason.decode!(body)

  defp reply(conn, "GET", "/v1/servers", _payload) do
    json(conn, %{
      "servers" => [
        %{
          "id" => 99,
          "name" => "hand-built-box",
          "status" => "running",
          "location" => %{"name" => "fsn1"},
          "public_net" => %{"ipv4" => %{"ip" => "203.0.113.5"}}
        }
      ]
    })
  end

  defp reply(conn, "GET", "/v1/datacenters", _payload) do
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

  defp reply(conn, "GET", "/v1/server_types", _payload) do
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

  defp reply(conn, "GET", "/v1/firewalls", _payload), do: json(conn, %{"firewalls" => []})
  defp reply(conn, "GET", "/v1/ssh_keys", _payload), do: json(conn, %{"ssh_keys" => []})
  defp reply(conn, "GET", "/v1/networks", _payload), do: json(conn, %{"networks" => []})

  defp reply(conn, "POST", "/v1/servers", payload) do
    json(conn, %{
      "server" => %{
        "id" => System.unique_integer([:positive]),
        "name" => payload["name"],
        "status" => "running",
        "server_type" => %{"name" => payload["server_type"]},
        "location" => %{"name" => "fsn1"},
        "public_net" => %{"ipv4" => %{"ip" => "203.0.113.10"}}
      }
    })
  end

  defp reply(conn, "POST", "/v1/ssh_keys", _payload) do
    json(conn, %{"ssh_key" => %{"id" => 1, "fingerprint" => "aa:bb"}})
  end

  defp reply(conn, _method, _path, payload) do
    json(conn, %{"network" => %{"id" => 1, "name" => payload["name"]}})
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end
end
