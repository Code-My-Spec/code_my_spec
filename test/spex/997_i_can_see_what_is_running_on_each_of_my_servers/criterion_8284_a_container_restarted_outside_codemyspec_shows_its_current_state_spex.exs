defmodule CodeMySpecSpex.Story997.Criterion8284Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8284 — A container restarted outside CodeMySpec shows its current state.

  The doctrine `Servers.list/1` already holds, one level down. That function
  reports what Hetzner says a box *is* rather than what we recorded; this one
  reports what the box says is *running on it*.

  It matters more here, because a deploy is a single moment and a container's
  life is everything after it. The deploy that started this container still
  says it succeeded — it did — and that record will keep saying so through
  every crash, restart and manual `docker stop` that follows.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A container restarted outside CodeMySpec shows its current state" do
    scenario "the uptime shown is the one since his own restart" do
      given_ "a linked server running the container CodeMySpec deployed", context do
        context = stage_servers(context, [provider_server(%{name: "web-1"})])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='web-1']")
        |> render_click()

        context =
          stage_containers(context, [
            container(%{name: "fuellytics", state: "running", status: "Up 6 days"})
          ])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers/web-1")
        html = render_async(view)

        assert html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='container'][data-name='fuellytics']")
               |> Floki.attribute("data-status") == ["Up 6 days"],
               "expected the original uptime to be showing before the restart"

        {:ok, context |> Map.put(:view, view)}
      end

      when_ "he restarts it from an SSH session of his own and reopens the page", context do
        # Nothing told CodeMySpec. That is the point — the box is the only
        # thing that knows, and the deploy record is unchanged and still true.
        context =
          stage_containers(context, [
            container(%{name: "fuellytics", state: "running", status: "Up 30 seconds"})
          ])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers/web-1")

        {:ok, Map.put(context, :html, render_async(view))}
      end

      then_ "the page shows the uptime since his restart", context do
        assert context.html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='container'][data-name='fuellytics']")
               |> Floki.attribute("data-status") == ["Up 30 seconds"],
               "the page showed a remembered uptime rather than the box's"

        {:ok, context}
      end

      then_ "and nothing on the page came from what the deploy recorded", context do
        # Scoped to the container rows. A deploy record legitimately mentions
        # six days ago — that is when it ran — so a page-wide search would
        # fail on the true half of the screen rather than on the stale half.
        statuses =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='container']")
          |> Floki.attribute("data-status")

        refute "Up 6 days" in statuses,
               "a container is still reporting the state it had before he touched it, " <>
                 "so something is reading our record of the deploy rather than the box"

        {:ok, context}
      end
    end
  end
end
