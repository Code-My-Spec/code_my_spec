defmodule CodeMySpecSpex.Story999.Criterion8304Spex do
  @moduledoc """
  Story 999 — I can fix what my setup is missing, and keep what I meant to leave
  Criterion 8304 — A record added for another tool stops being reported as broken.

  Not every leftover is a leak. A DNS record added by hand for a different
  tool, or mail records kept after moving off CodeMySpec mail, are deliberate —
  and a page that keeps calling them broken teaches Sam to skip the red, which
  costs more than the resource does.

  The marking is a record of his intent, and it is **his** rather than ours: it
  keys on the provider and the resource's identity, not on a row of ours,
  because the things most needing marking are exactly the ones setup never
  created and has nothing to hang a flag on.

  Reversible, and still listed. Marking says "keep this", not "hide this" —
  a resource nobody can see is the failure this whole epic keeps finding.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A record added for another tool stops being reported as broken", criterion: 834 do
    scenario "marking a deliberate leftover clears it without hiding it" do
      given_ "a box setup once provisioned, since destroyed", context do
        # Only an address that was ours can dangle, so the leftover has to
        # have been ours once — see story 998's criterion 8293.
        context =
          scripted_run(context, %{
            server: fn ->
              {:ok,
               [
                 %{
                   kind: "server",
                   location: "hetzner/old-uat",
                   identifier: "environment=uat ip=203.0.113.99"
                 }
               ]}
            end
          })

        # Retargeted onto the console (provisioning-console-step6, unmerged).
        # The final then_ checks the account reads fully healthy
        # (`data-problems == "0"`) once the leftover is marked — which,
        # same as 998's criterion 831, means every checklist entry has to
        # read non-`:missing` first, not just the scripted server. See
        # criterion 831's given_ for why each step is run individually
        # across its resource group and (for environment-scoped steps)
        # each environment.
        {:ok, server_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(server_view, :server)

        {:ok, repository_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/repository")

        run_console_step(repository_view, :repository)

        {:ok, mail_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/mail")

        run_console_step(mail_view, :email)
        run_console_step(mail_view, :inbound)

        for env <- ["uat", "prod"] do
          {:ok, servers_view, _html} =
            live(
              context.conn,
              "/app/projects/#{context.project.id}/console/resources/servers?env=#{env}"
            )

          run_console_step(servers_view, :secrets)
          run_console_step(servers_view, :callback_credential)

          {:ok, dns_domain_view, _html} =
            live(
              context.conn,
              "/app/projects/#{context.project.id}/console/resources/dns_domain?env=#{env}"
            )

          run_console_step(dns_domain_view, :domain)
          run_console_step(dns_domain_view, :dns)
          run_console_step(dns_domain_view, :tls)

          {:ok, deploys_view, _html} =
            live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

          deploys_view
          |> form(
            "[data-test='deploy-row'][data-environment='#{env}'] [data-test='deploy-environment-form']",
            %{"environment" => env}
          )
          |> render_submit()

          {:ok, storage_view, _html} =
            live(
              context.conn,
              "/app/projects/#{context.project.id}/console/resources/storage_backups?env=#{env}"
            )

          run_console_step(storage_view, :storage)
          run_console_step(storage_view, :backups)

          {:ok, widget_view, _html} =
            live(
              context.conn,
              "/app/projects/#{context.project.id}/console/resources/widget?env=#{env}"
            )

          run_console_step(widget_view, :widget)
        end

        # `content` plans one entry total, pinned to the primary
        # environment (`prod`) — see criterion 831.
        {:ok, publishing_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/publishing?env=prod"
          )

        run_console_step(publishing_view, :content)

        {:ok, context}
      end

      given_ "and a record still pointing at its address, kept on purpose for another tool",
             context do
        context =
          stage_inventory(context, %{
            hetzner: [],
            cloudflare: [
              inventory_resource(%{
                kind: "dns_record",
                location: "tracker.example.com",
                identifier: "A 203.0.113.99"
              })
            ],
            resend: [],
            storage: []
          })

        {:ok, view, _html} = live(context.conn, "/app/resources")
        html = render_async(view, 5_000)

        assert html
               |> Floki.parse_document!()
               |> Floki.find("[data-test='resource'][data-location='tracker.example.com']")
               |> Floki.attribute("data-status") == ["dangling"],
               "expected the record to start out flagged, or this proves nothing"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he marks it as deliberate", context do
        html =
          context.view
          |> element("[data-test='keep'][phx-value-location='tracker.example.com']")
          |> render_click()

        {:ok, context |> Map.put(:html, html) |> Map.put(:document, Floki.parse_document!(html))}
      end

      then_ "it is no longer counted against the account's health", context do
        row =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='tracker.example.com']"
          )

        refute Floki.attribute(row, "data-status") == ["dangling"],
               "a resource he has said he wants is still being reported as broken"

        {:ok, Map.put(context, :row, row)}
      end

      then_ "and it is still listed, shown as kept on purpose rather than hidden", context do
        assert context.row != [],
               "marking a resource removed it from the page — which is how a thing that " <>
                 "bills quietly stops being looked at"

        assert Floki.attribute(context.row, "data-status") == ["kept"],
               "the row does not say it is kept deliberately, so next month it reads as " <>
                 "something nobody has looked at"

        {:ok, context}
      end

      then_ "and the account reads as healthy again", context do
        summary = Floki.find(context.document, "[data-test='health-summary']")

        assert Floki.attribute(summary, "data-status") == ["healthy"],
               "the only problem was a resource he has now accounted for, and the page " <>
                 "still says something is wrong"

        assert Floki.attribute(summary, "data-problems") == ["0"]

        {:ok, context}
      end
    end
  end
end
