defmodule CodeMySpecSpex.Story994.Criterion8267Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8267 — Nothing is created until Sam says yes to a stated cost.

  The meter starts the moment the box exists, so the confirmation is not
  ceremony — it is the last point at which the answer is still free.

  The domain step already holds this line, and says why on the page:
  "Registration is not refundable, so nothing is bought without that second
  step." A server is cheaper per mistake and easier to make by accident, which
  is an argument for the same discipline rather than against it.

  The cost has to be stated, not implied. A confirmation that does not say
  what it costs is a confirmation of nothing in particular.

  Surface: `CodeMySpecWeb.ServersLive` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Nothing is created until Sam says yes to a stated cost" do
    scenario "choosing a size costs nothing until it is confirmed" do
      given_ "Sam has chosen a size and a location", context do
        owner = self()

        context =
          stage_servers(context, [],
            create: fn _scope, attrs ->
              send(owner, {:created, attrs})
              {:ok, provider_server(%{name: "confirmed-box"})}
            end
          )

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        html =
          view
          |> form("[data-test='provision-form']", server: %{size: "cpx11", location: "fsn1"})
          |> render_submit()

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "he is shown what it will cost and has not yet confirmed", context do
        cost =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provision-cost']")

        assert cost != [],
               "he was asked to confirm without being told what it costs"

        assert Floki.text(cost) =~ ~r/[€$£]|\d/,
               "the cost element names no actual figure"

        {:ok, Map.put(context, :cost, cost)}
      end

      then_ "no server exists at the provider", context do
        refute_received {:created, _attrs},
                        "a server was created before Sam confirmed anything — the meter " <>
                          "started on a decision he had not made yet"

        assert context.html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server']") == []

        {:ok, context}
      end

      then_ "and only his confirmation creates one", context do
        html =
          context.view
          |> element("[data-test='provision-confirm']")
          |> render_click()

        assert_received {:created, _attrs}

        assert html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server'][data-name='confirmed-box']") != []

        {:ok, context}
      end
    end
  end
end
