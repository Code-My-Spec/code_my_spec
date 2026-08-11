defmodule CodeMySpecSpex.Story994.Criterion8265Spex do
  @moduledoc """
  Story 994 — I can see and link the servers I already own
  Criterion 8265 — A new box is created without leaving the screen.

  The decision behind this one was taken deliberately and could have gone the
  other way (question 63b51408). Domain registration became a console errand
  because Cloudflare's API cannot price a name we do not hold, and that turned
  out fine. Servers are different: a domain is bought once, but a server is
  replaced, resized and rebuilt repeatedly, so a detour to the provider
  recurs — against a product whose promise is infrastructure Sam never
  maintains.

  So provisioning stays here. A box made on this screen is his, in his own
  provider account, and arrives already linked because he made it here.

  Surface: `CodeMySpecWeb.ServerLive.Index` at `/app/servers`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account

  spex "A new box is created without leaving the screen" do
    scenario "provisioning from the screen produces a linked server" do
      given_ "Sam is on the servers screen with nothing provisioned yet", context do
        recorder = Fixtures.call_recorder()

        context =
          stage_servers(context, [],
            create: fn _scope, attrs ->
              Fixtures.record_call(recorder, {:created, attrs})
              {:ok, provider_server(Map.merge(%{name: "new-box"}, attrs))}
            end
          )

        {:ok, view, _html} = live(context.conn, "/app/servers")

        {:ok, Map.merge(context, %{view: view, recorder: recorder})}
      end

      when_ "he asks for a new server and confirms it", context do
        context.view
        |> form("[data-test='provision-form']", server: %{size: "cpx11", location: "fsn1"})
        |> render_submit()

        html =
          context.view
          |> element("[data-test='provision-confirm']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the server is created in his own provider account", context do
        assert [{:created, attrs}] = Fixtures.recorded_calls(context.recorder)
        assert attrs[:size] == "cpx11" or attrs["size"] == "cpx11"

        {:ok, context}
      end

      then_ "and it joins the list already linked, because he made it here", context do
        row =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='server'][data-name='new-box']")

        assert row != [], "the newly provisioned server is not on the screen"

        assert Floki.attribute(row, "data-linked") == ["true"],
               "a server Sam created here should not need linking afterwards"

        {:ok, context}
      end
    end
  end
end
