defmodule CodeMySpecSpex.Story997.Criterion8288Spex do
  @moduledoc """
  Story 997 — I can see what is running on each of my servers
  Criterion 8288 — The certificate and DNS record made for this box are on its page.

  Setup already records what it created. What it does not do is make those
  records answerable from the box's side: they live as a JSONB blob on
  `provisioning_steps`, keyed to a project, with the environment written into
  an identifier string. Asking "what is on this machine" means scanning every
  project's steps and matching text.

  That is the same shape as the credential defect on story 994 — the record
  exists and is correct, it is simply not addressable at the grain being
  asked. The fix is a `server_id`, so a server can be asked directly.

  The address is the reason it matters. A certificate and a DNS record both
  point at an IP, and when the box behind that IP is released they are the
  two things left pointing at somebody else's machine.

  Surface: `CodeMySpecWeb.ServerLive.Show` at `/app/servers/:name`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The certificate and DNS record made for this box are on its page" do
    scenario "what setup created for a box is listed against that box" do
      given_ "setup has provisioned Sam's UAT box, its certificate and its DNS record",
             context do
        # Driven through the provisioning surface rather than written straight
        # into the tables, so the resources on the page are the ones the steps
        # genuinely recorded.
        context =
          scripted_run(context, %{
            server: fn ->
              {:ok,
               [
                 %{
                   kind: "server",
                   location: "hetzner/uat-box",
                   identifier: "environment=uat ip=203.0.113.10"
                 }
               ]}
            end,
            tls: fn ->
              {:ok,
               [
                 %{
                   kind: "certificate",
                   location: "https://uat.example.com",
                   identifier: "environment=uat"
                 }
               ]}
            end,
            dns: fn ->
              {:ok,
               [
                 %{
                   kind: "dns_record",
                   location: "uat.example.com",
                   identifier: "environment=uat A 203.0.113.10"
                 }
               ]}
            end
          })

        # The server step's real write-back, which `scripted_run/2` replaces
        # along with the rest of the step. Without it the box is provisioned
        # and nothing records which environment it carries, so nothing can
        # find it again — the same leak the step halts on in production.
        CodeMySpecSpex.Fixtures.record_environment_server(
          context.scope,
          "uat",
          "uat-box",
          "203.0.113.10"
        )

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        await_step_state(view, "dns", "done")

        {:ok, context}
      end

      given_ "and the box is linked to his account", context do
        context = stage_servers(context, [provider_server(%{name: "uat-box"})])

        {:ok, view, _html} = live(context.conn, ~p"/app/servers")

        view
        |> element("[data-test='link-server'][phx-value-name='uat-box']")
        |> render_click()

        {:ok, context}
      end

      when_ "he opens that server", context do
        context = stage_containers(context, [])

        {:ok, _view, html} = live(context.conn, ~p"/app/servers/uat-box")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the certificate and the DNS record are listed against it", context do
        kinds =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource']")
          |> Floki.attribute("data-kind")

        assert "certificate" in kinds,
               "the certificate setup made for this box is not on the box's page"

        assert "dns_record" in kinds,
               "the DNS record pointing at this box is not on the box's page"

        {:ok, context}
      end

      then_ "and each says what it actually is, not merely that it exists", context do
        locations =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource']")
          |> Floki.attribute("data-location")

        assert "https://uat.example.com" in locations,
               "the certificate is listed without saying what host it covers"

        assert "uat.example.com" in locations,
               "the DNS record is listed without saying what name it answers for"

        {:ok, context}
      end
    end
  end
end
