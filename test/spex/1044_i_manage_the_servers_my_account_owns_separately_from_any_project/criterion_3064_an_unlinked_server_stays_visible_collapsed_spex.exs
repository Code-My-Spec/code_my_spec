defmodule CodeMySpecSpex.Story1044.Criterion3064Spex do
  @moduledoc """
  Story 1044 — I manage the servers my account owns, separately from any project
  Criterion 3064 — An unlinked server stays visible, collapsed.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Provisioning.Hetzner

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unlinked server is collapsed, never hidden" do
    scenario "with one server already linked, a second, unlinked one stays collapsed behind a count" do
      given_ "Hetzner reports one server, and Sam has already linked it", context do
        CodeMySpecSpex.Fixtures.connect_hetzner(context.scope)
        {:ok, state} = Agent.start_link(fn -> [linked_box()] end)

        plug = fn conn ->
          {:ok, _body, conn} = Plug.Conn.read_body(conn)
          reply(conn, conn.method, conn.request_path, state)
        end

        Req.Test.stub(Hetzner, plug)

        {:ok, first_visit, _html} = live(context.conn, "/app/servers")

        first_visit
        |> element("[data-test='link-server'][phx-value-name='already-linked-box']")
        |> render_click()

        {:ok, Map.put(context, :hetzner_state, state)}
      end

      when_ "Sam reloads the page, and the provider now also reports a second, unlinked box",
            context do
        Agent.update(context.hetzner_state, &[unlinked_box() | &1])

        {:ok, servers_live, _html} = live(context.conn, "/app/servers")
        {:ok, Map.put(context, :servers_live, servers_live)}
      end

      then_ "the linked server renders outright, and the new unlinked one stays collapsed",
            context do
        assert has_element?(
                 context.servers_live,
                 "[data-test='server'][data-name='already-linked-box'][data-linked='true']"
               ),
               "expected the linked server to render outright"

        refute has_element?(
                 context.servers_live,
                 "[data-test='unlinked-servers'] [data-test='server'][data-name='hand-built-box']"
               ),
               "with something already linked, the new unlinked box should start collapsed"

        assert has_element?(
                 context.servers_live,
                 "[data-test='unlinked-count'][data-count='1']"
               ),
               "the collapsed unlinked server must still be counted, not omitted"

        {:ok, context}
      end

      when_ "he expands the unlinked section", context do
        context.servers_live
        |> element("[data-test='unlinked-count']")
        |> render_click()

        {:ok, context}
      end

      then_ "the unlinked server is now visible too", context do
        assert has_element?(
                 context.servers_live,
                 "[data-test='unlinked-servers'] [data-test='server'][data-name='hand-built-box']"
               ),
               "expanding the count must reveal the unlinked server, not merely change the label"

        {:ok, context}
      end
    end
  end

  defp linked_box do
    %{
      "id" => 1,
      "name" => "already-linked-box",
      "status" => "running",
      "location" => %{"name" => "fsn1"},
      "public_net" => %{"ipv4" => %{"ip" => "203.0.113.1"}}
    }
  end

  defp unlinked_box do
    %{
      "id" => 2,
      "name" => "hand-built-box",
      "status" => "running",
      "location" => %{"name" => "fsn1"},
      "public_net" => %{"ipv4" => %{"ip" => "203.0.113.2"}}
    }
  end

  defp reply(conn, "GET", "/v1/servers", state) do
    json(conn, %{"servers" => Agent.get(state, & &1)})
  end

  defp reply(conn, _method, _path, _state), do: json(conn, %{})

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(201, Jason.encode!(body))
  end
end
