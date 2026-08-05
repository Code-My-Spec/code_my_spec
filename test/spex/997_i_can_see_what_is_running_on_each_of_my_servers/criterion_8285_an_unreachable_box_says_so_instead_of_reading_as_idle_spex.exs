defmodule CodeMySpecSpex.Story997.Criterion8285Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8285 — An unreachable box says so instead of reading as idle.

  The same lie as criterion 8259, one layer in. There an empty server list
  claimed the account had no servers; here an empty container list claims the
  box is doing nothing. Both are a failure to ask, rendered as an answer.

  This one is worse in one respect: a box running nothing looks fine. Sam has
  no reason to investigate a quiet machine, so the page has to be the thing
  that tells him it could not see, and it has to say why — a refused key and a
  dead box are different problems with different fixes.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "An unreachable box says so instead of reading as idle" do
    scenario "a box that stopped answering is reported, not rendered as empty" do
      given_ "a linked server that is running containers", context do
        # Stated so the absence below is a lie rather than a fact: things are
        # running on this box, we simply cannot see them.
        context = stage_servers(context, [provider_server(%{name: "web-1"})])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='web-1']")
        |> render_click()

        {:ok, context}
      end

      when_ "the box has stopped accepting SSH", context do
        context = stage_containers(context, {:error, :unreachable})

        {:ok, _view, html} = live(context.conn, ~p"/app/servers/web-1")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the page says the box could not be reached, and why", context do
        document = Floki.parse_document!(context.html)
        error = Floki.find(document, "[data-test='containers-error']")

        assert error != [],
               "a box that could not be reached produced no error on the page"

        assert Floki.text(error) =~ ~r/reach|connect|refus|ssh/i,
               "the error must say what went wrong, not merely that something did"

        {:ok, Map.put(context, :document, document)}
      end

      then_ "and it does not show an empty list, which would read as a box doing nothing",
            context do
        assert Floki.find(context.document, "[data-test='container']") == [],
               "containers were invented for a box nobody could reach"

        assert Floki.find(context.document, "[data-test='no-containers']") == [],
               "the page claimed nothing is running on a box it had simply failed to ask"

        {:ok, context}
      end

      then_ "and what setup recorded about the box is still on the screen", context do
        # The provider read failing says nothing about our own records, and
        # blanking them would lose the half of the page we can still vouch for.
        assert Floki.find(context.document, "[data-test='server-detail']") != [],
               "an unreachable box took the whole page down with it"

        {:ok, context}
      end
    end
  end
end
