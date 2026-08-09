defmodule CodeMySpecSpex.Story994.Criterion8260Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8260 — Linking a running server does not touch it.

  Linking is a note we make about a box, not something we do to it. Sam's
  first use of this screen will be on machines already serving real traffic,
  and if linking installed an agent, rewrote a firewall or restarted anything,
  the feature would be unusable exactly where it is most wanted.

  So the assertion is a negative: the provider was asked nothing that changes
  the server.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "Linking a running server does not touch it" do
    scenario "a live server is recorded and otherwise left alone" do
      given_ "a server already serving live traffic", context do
        owner = self()

        context =
          stage_servers(
            context,
            [provider_server(%{name: "live-box", ip: "203.0.113.9", status: "running"})],
            # Any provider call that would alter the machine reports itself
            # here. The criterion is that none of them fire.
            on_mutate: fn action, name -> send(owner, {:mutated, action, name}) end
          )

        {:ok, context}
      end

      when_ "Sam links it", context do
        {:ok, view, _html} = live(context.conn, "/app/servers")

        html =
          view
          |> element("[data-test='link-server'][phx-value-name='live-box']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "CodeMySpec records it", context do
        assert context.html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server'][data-name='live-box']")
               |> Floki.attribute("data-linked") == ["true"],
               "the server was not recorded as linked"

        {:ok, context}
      end

      then_ "and nothing was installed, restarted, reconfigured or rebooted", context do
        refute_received {:mutated, _action, "live-box"}

        # And it is still running, which is the observable half of the same
        # claim — a link that rebooted the box would show here eventually.
        assert context.html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='server'][data-name='live-box']")
               |> Floki.attribute("data-status") == ["running"]

        {:ok, context}
      end
    end
  end
end
