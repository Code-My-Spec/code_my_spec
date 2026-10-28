defmodule CodeMySpecSpex.Story999.Criterion8306Spex do
  @moduledoc """
  Story 999 — I can fix what my setup is missing, and keep what I meant to leave
  Criterion 8306 — Marking survives the resource list being rebuilt.

  The list is rebuilt on every page load — that is the point of it, and why it
  can be trusted. Nothing on the page is stored between visits.

  Which is exactly the problem the marking has to survive. It cannot be a flag
  on a resource row, because the resources are not rows; they are whatever the
  providers said thirty seconds ago. A marking that lived on them would be
  gone by the next load, and a feature you have to redo every time you look is
  worse than not having it — Sam would mark twice, notice, and stop trusting
  the page.

  So it keys on what stays the same about a resource across rebuilds: the
  provider and its identity. Nothing about our record of it, because for the
  resources that most need marking we have no record at all.

  Surface: `CodeMySpecWeb.ResourceLive.Index`, the console's Inventory.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :devops_without_telemetry
  setup :connect_providers

  spex "Marking survives the resource list being rebuilt", criterion: 836 do
    scenario "a marked bucket is still marked on the next visit" do
      given_ "a bucket setup once made for an environment that no longer names it", context do
        context =
          scripted_run(context, %{
            storage: fn ->
              {:ok,
               [
                 %{
                   kind: "bucket",
                   location: "storage/old-dumps",
                   identifier: "environment=uat"
                 }
               ]}
            end
          })

        # Retargeted onto the console (provisioning-console-step6, unmerged).
        # The final then_ checks the account reads fully healthy, which
        # (same as 998's criterion 831 and 999's criterion 834) means every
        # checklist entry has to read non-`:missing`, not just the scripted
        # `storage` step — so every step is run individually across its
        # resource group and, for environment-scoped steps, each
        # environment. `storage` itself is environment-scoped; running it
        # on both environments calls the same scripted function twice, but
        # `recorded_buckets` is a set keyed by name, so the duplicate
        # doesn't change what's dangling.
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

        context =
          stage_inventory(context, %{
            hetzner: [],
            cloudflare: [],
            resend: [],
            storage: [inventory_resource(%{kind: "bucket", location: "storage/old-dumps"})]
          })

        {:ok, context}
      end

      given_ "and Sam has marked it as deliberate", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/inventory")

        render_settled(view)

        view
        |> element("[data-test='keep'][phx-value-location='storage/old-dumps']")
        |> render_click()

        {:ok, context}
      end

      when_ "the page re-reads every provider from scratch", context do
        # A fresh mount. Nothing carries over in the socket, so anything still
        # on the screen came back from storage rather than from memory.
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/inventory")

        {:ok, Map.put(context, :document, Floki.parse_document!(render_settled(view)))}
      end

      then_ "the bucket is still shown as kept on purpose", context do
        row =
          Floki.find(
            context.document,
            "[data-test='resource'][data-location='storage/old-dumps']"
          )

        assert row != [], "the bucket is not on the page at all"

        assert Floki.attribute(row, "data-status") == ["kept"],
               "the marking did not survive the rebuild, so it lived on the resource — " <>
                 "and the resources are whatever the provider said a moment ago"

        {:ok, Map.put(context, :row, row)}
      end

      then_ "and he did not have to mark it again", context do
        summary = Floki.find(context.document, "[data-test='health-summary']")

        assert Floki.attribute(summary, "data-status") == ["healthy"],
               "the account reports unhealthy on a fresh load over a resource he had " <>
                 "already accounted for, which is the version of this feature he would " <>
                 "stop using"

        {:ok, context}
      end
    end
  end
end
