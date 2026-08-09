defmodule CodeMySpecSpex.Story997.Criterion8290Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8290 — A box that hangs leaves the rest of the page usable.

  A box that refuses a connection fails fast. A box that accepts one and never
  answers does not fail at all — SSH will sit there, and a mount that waits on
  it takes the whole page down with it, including the half that needed no
  network to render.

  The two halves have different sources and should have different fates. What
  setup recorded is ours and is already in the database; only the container
  list depends on a machine that may or may not be listening. So the records
  render immediately, the container list says it is still reading, and the
  read gives up on a deadline of its own.

  Giving up is the part worth stating. A spinner that never resolves is the
  same failure as a hang, just with better manners.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A box that hangs leaves the rest of the page usable" do
    scenario "the records render while the box is still being read" do
      given_ "a linked server that accepts connections but never answers", context do
        context = stage_servers(context, [provider_server(%{name: "wedged-1"})])

        {:ok, view, _html} = live(context.conn, "/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='wedged-1']")
        |> render_click()

        # The reader owns the deadline, so a box that never answers arrives
        # here as a timeout rather than as a process still sitting on a socket.
        context = stage_containers(context, {:error, :timeout})

        {:ok, context}
      end

      when_ "he opens that server", context do
        {:ok, view, html} = live(context.conn, "/app/servers/wedged-1")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "what setup recorded is on the screen straight away", context do
        document = Floki.parse_document!(context.html)

        assert Floki.find(document, "[data-test='server-detail']") != [],
               "the page had nothing on it while the box was being read, so one " <>
                 "unreachable machine cost him the half of the screen that needed no network"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and the container list says it is still being read", context do
        assert Floki.find(context.document, "[data-test='containers-pending']") != [],
               "the container area rendered as though it had an answer before it had one"

        {:ok, context}
      end

      then_ "and it gives up after a stated wait rather than spinning forever", context do
        html = render_async(context.view)
        document = Floki.parse_document!(html)

        assert Floki.find(document, "[data-test='containers-pending']") == [],
               "the page is still claiming to be reading a box it has already given up on"

        error = Floki.find(document, "[data-test='containers-error']")

        assert error != [],
               "the read ended and said nothing, which leaves him unable to tell a slow " <>
                 "box from an empty one"

        assert Floki.text(error) =~ ~r/time|wait|respond|answer/i,
               "the message does not say that the box ran out of time"

        {:ok, context}
      end
    end
  end
end
