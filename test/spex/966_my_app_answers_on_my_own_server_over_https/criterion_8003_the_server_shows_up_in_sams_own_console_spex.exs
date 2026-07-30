defmodule CodeMySpecSpex.Story966.Criterion8003Spex do
  @moduledoc """
  Story 966 — My app answers on my own server over HTTPS
  Criterion 8003 — The server shows up in Sam's own console.

  The server is provisioned into Sam's own Hetzner account and he is the
  one billed for it. Nothing is held on the platform's side — he can stop
  paying CodeMySpec tomorrow and keep the box.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "hetzner_server_create_ok"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The server shows up in Sam's own console" do
    scenario "the provisioned server is recorded under Sam's own account" do
      given_ "Sam is on the setup status page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the server step has run", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='server'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the server is recorded under his own account", context do
        server =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='server']")

        # Anchor: a server resource was recorded at all.
        assert server != [], "expected the run to record the provisioned server"

        owner = server |> Floki.attribute("data-owner") |> List.first()

        assert owner == "user",
               "expected the server to be owned by Sam, got #{inspect(owner)}"

        location = server |> Floki.attribute("data-location") |> List.first()

        assert is_binary(location) and location != "",
               "expected the record to name where the server lives so Sam can find it in his console"

        {:ok, context}
      end

      then_ "nothing about it is held on the platform's side", context do
        refute context.html =~ ~r/data-kind="server"[^>]*data-owner="platform"/,
               "expected no part of the server to be held by the platform"

        {:ok, context}
      end
    end
  end
end
