defmodule CodeMySpecSpex.Story997.Criterion8286Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8286 — A crashed container is on the screen, with its exit code.

  `docker ps` without `-a` hides exactly the container Sam came to find. A
  page built from the default listing would show a healthy box with one
  service quietly missing, and missing reads as "I forgot what I deployed"
  rather than as "it died".

  Same shape as criterion 8262, where a linked server the provider no longer
  reports is marked rather than dropped. Absence is never self-explanatory:
  the thing that stopped has to be on the screen saying it stopped.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A crashed container is on the screen, with its exit code" do
    scenario "an exited container is listed with why it exited" do
      given_ "a linked server whose UAT container died an hour ago", context do
        context = stage_servers(context, [provider_server(%{name: "web-1"})])

        {:ok, view, _html} = live(context.conn, "/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='web-1']")
        |> render_click()

        context =
          stage_containers(context, [
            container(%{name: "fuellytics", state: "running", status: "Up 6 days"}),
            container(%{
              name: "fuellytics-uat",
              state: "exited",
              status: "Exited (1) About an hour ago",
              exit_code: 1
            })
          ])

        {:ok, context}
      end

      when_ "he opens the server", context do
        {:ok, view, _html} = live(context.conn, "/app/servers/web-1")

        {:ok, Map.put(context, :html, render_async(view))}
      end

      then_ "the exited container is listed alongside the running one", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='container'][data-name='fuellytics']") != [],
               "the running container is missing"

        assert Floki.find(document, "[data-test='container'][data-name='fuellytics-uat']") != [],
               "the container that died is not on the screen at all, so the box reads " <>
                 "as healthy with one service simply forgotten"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "it shows that it exited, and with what code", context do
        row = Floki.find(context.document, "[data-test='container'][data-name='fuellytics-uat']")

        assert Floki.attribute(row, "data-state") == ["exited"]

        assert Floki.attribute(row, "data-exit-code") == ["1"],
               "the exit code is what tells him whether it was killed or crashed"

        assert Floki.text(row) =~ "1",
               "the exit code is recorded in an attribute but never shown"

        {:ok, Map.put(context, :row, row)}
      end

      then_ "and it does not read as healthy", context do
        running = Floki.find(context.document, "[data-test='container'][data-name='fuellytics']")

        refute Floki.attribute(context.row, "data-state") ==
                 Floki.attribute(running, "data-state"),
               "the dead container is presented identically to the live one"

        {:ok, context}
      end
    end
  end
end
