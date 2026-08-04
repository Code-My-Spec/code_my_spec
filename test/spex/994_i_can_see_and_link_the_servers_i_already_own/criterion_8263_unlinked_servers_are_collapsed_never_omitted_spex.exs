defmodule CodeMySpecSpex.Story994.Criterion8263Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8263 — Unlinked servers are collapsed, never omitted.

  A box you cannot see is a box that keeps billing. Linking is how Sam tells
  CodeMySpec a server matters to him; it must not become how a server
  disappears from view.

  So the screen may de-emphasise what is unlinked — the linked ones are what
  he works with daily — but the count is always visible without expanding
  anything, and the servers themselves are always reachable from the same
  screen.

  Surface: `CodeMySpecWeb.ServersLive` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Unlinked servers are collapsed, never omitted" do
    scenario "the unlinked ones are counted up front and reachable from the same screen" do
      given_ "Sam has five servers and has linked two of them", context do
        context =
          stage_servers(
            context,
            Enum.map(1..5, &provider_server(%{name: "box-#{&1}"}))
          )

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        for name <- ["box-1", "box-2"] do
          view
          |> element("[data-test='link-server'][phx-value-name='#{name}']")
          |> render_click()
        end

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he opens the servers screen", context do
        {:ok, view, html} = live(context.conn, ~p"/app/servers")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "the two linked servers are shown", context do
        linked =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-linked='true']")
          |> Floki.attribute("data-name")
          |> Enum.sort()

        assert linked == ["box-1", "box-2"]

        {:ok, context}
      end

      then_ "the count of unlinked servers is visible without expanding anything", context do
        count =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='unlinked-count']")

        assert count != [],
               "nothing on the collapsed screen says how many servers are not linked"

        assert Floki.attribute(count, "data-count") == ["3"]

        {:ok, context}
      end

      then_ "and the remaining three are reachable from the same screen", context do
        html =
          context.view
          |> element("[data-test='unlinked-count']")
          |> render_click()

        unlinked =
          html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-linked='false']")
          |> Floki.attribute("data-name")
          |> Enum.sort()

        assert unlinked == ["box-3", "box-4", "box-5"],
               "the unlinked servers are not reachable from this screen at all"

        {:ok, context}
      end
    end
  end
end
