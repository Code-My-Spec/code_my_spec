defmodule CodeMySpecSpex.Story997.Criterion8287Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8287 — A shared box lists both projects' containers.

  The page reports the box, and a box does not know about projects. Filtering
  to the open project would be us imposing a boundary the machine does not
  have — and on the one screen whose whole job is saying what is actually
  there.

  Not hypothetical: story 986 puts several projects on one CX32 deliberately,
  and `kamal-proxy` belongs to none of them while terminating TLS for all.
  A list that only showed the current project's containers would omit the
  process that decides whether any of them are reachable.

  This is criterion 8261's rule one level in — servers belong to the account,
  so what runs on them does too.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A shared box lists both projects' containers" do
    scenario "one box, every container on it" do
      given_ "a linked server carrying two projects and the proxy in front of them",
             context do
        context = stage_servers(context, [provider_server(%{name: "shared-1"})])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='shared-1']")
        |> render_click()

        context =
          stage_containers(context, [
            container(%{name: "kamal-proxy", image: "basecamp/kamal-proxy:latest"}),
            container(%{name: "fuellytics", image: "ghcr.io/sam/fuellytics:sha-aaa"}),
            container(%{name: "legwork", image: "ghcr.io/sam/legwork:sha-bbb"})
          ])

        {:ok, context}
      end

      given_ "and he also owns a second project in the same account", context do
        {:ok, form, _html} = live(context.conn, ~p"/app/projects/new")

        form
        |> form("[data-test='project-form']", project: %{name: "second-project-997"})
        |> render_submit()

        {:ok, context}
      end

      when_ "he opens that server from whichever project he happens to have open", context do
        {:ok, _view, html} = live(context.conn, ~p"/app/servers/shared-1")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "containers from both projects are listed", context do
        names =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='container']")
          |> Floki.attribute("data-name")

        assert "fuellytics" in names and "legwork" in names,
               "the page filtered the box's containers down to one project's, which is a " <>
                 "boundary the machine does not have"

        {:ok, Map.put(context, :names, names)}
      end

      then_ "and so is the proxy, which no project owns", context do
        assert "kamal-proxy" in context.names,
               "the process that decides whether anything on this box is reachable was " <>
                 "left off because it belongs to no project"

        {:ok, context}
      end
    end
  end
end
