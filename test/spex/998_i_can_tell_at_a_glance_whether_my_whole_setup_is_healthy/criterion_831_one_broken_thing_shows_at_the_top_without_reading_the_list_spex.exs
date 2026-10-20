defmodule CodeMySpecSpex.Story998.Criterion8297Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8297 — One broken thing shows at the top without reading the list.

  The page has two readers and only one of them knows what any of this is.

  For the other, a list of forty resources is not an answer to "are we okay" —
  it is a research task, and the honest thing is to do the arithmetic for them.
  One number, before any of the detail, that says whether today is a bad day.

  The counterpart matters as much: exactly one thing red when exactly one thing
  is wrong. A page that colours half the list amber to look thorough teaches
  the reader that red means nothing, and then the page has cost them the one
  signal it existed to give.

  Surface: `CodeMySpecWeb.ResourceLive.Index`, the console's Inventory.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :devops_without_telemetry
  setup :connect_providers

  spex "One broken thing shows at the top without reading the list", criterion: 831 do
    scenario "everything in place except one record" do
      given_ "setup once provisioned a box at .99", context do
        # A record can only dangle against an address that was ours, so the
        # premise needs a box on record before one can be released.
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
        # Unlike the other 997/998/999 retargets, this one can't get away
        # with running only the scripted step: `problems` counts every
        # checklist entry still `:missing` (resources.ex), and the old
        # whole-run cascade left every *other* step `:done`-with-no-resources
        # along the way. Reproducing "everything is set up, then one box died
        # behind setup's back" means actually running every step the plan
        # expects — project-scoped once, environment-scoped once per
        # environment — so the checklist carries zero `:missing` entries and
        # the dangling DNS record is the only problem left to count.
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

        # Unlike the other environment-scoped steps, `content` plans one
        # entry total, pinned to the primary environment (`prod`, when it
        # exists) — `Provisioning.plan_environments/2`'s special case for
        # `:content`. Visiting it per-environment above would 404 on uat's
        # "nothing in this environment yet".
        {:ok, publishing_view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/publishing?env=prod"
          )

        run_console_step(publishing_view, :content)

        {:ok, context}
      end

      given_ "and everything else is in place, except that one record", context do
        context =
          stage_inventory(context, %{
            hetzner: [
              inventory_resource(%{
                kind: "server",
                location: "hetzner/uat-box",
                identifier: "203.0.113.10"
              }),
              inventory_resource(%{kind: "ssh_key", location: "hetzner/codemyspec"}),
              inventory_resource(%{kind: "firewall", location: "hetzner/web"})
              # Deliberately no bucket. A bucket is judged against the
              # environments that name it, and with no project deployed here
              # there is nothing to name one — it would dangle correctly and
              # make this scenario's premise false rather than exercising it.
            ],
            cloudflare: [
              inventory_resource(%{
                kind: "dns_record",
                location: "uat.example.com",
                identifier: "A 203.0.113.10"
              }),
              inventory_resource(%{
                kind: "dns_record",
                location: "gone.example.com",
                identifier: "A 203.0.113.99"
              })
            ],
            resend: [
              inventory_resource(%{kind: "sending_domain", location: "resend/example.com"})
            ]
          })

        {:ok, context}
      end

      when_ "someone who does not know what a DNS record is opens the page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/inventory")

        {:ok, context |> Map.put(:document, Floki.parse_document!(render_async(view, 5_000)))}
      end

      then_ "the page reports the account unhealthy before any resource is read", context do
        summary = Floki.find(context.document, "[data-test='health-summary']")

        assert summary != [],
               "there is nothing to read but the list itself, so the answer to 'are we " <>
                 "okay' is a research task"

        assert Floki.attribute(summary, "data-status") == ["unhealthy"]

        {:ok, Map.put(context, :summary, summary)}
      end

      then_ "and it says how many things are wrong", context do
        assert Floki.attribute(context.summary, "data-problems") == ["1"],
               "the count is the whole point — one is a bad afternoon and twenty is a " <>
                 "bad week, and they need different reactions"

        assert Floki.text(context.summary) =~ "1"

        {:ok, context}
      end

      then_ "and the one thing that is wrong is the only thing marked red", context do
        flagged =
          context.document
          |> Floki.find("[data-test='resource'][data-status='dangling']")
          |> Floki.attribute("data-location")

        assert flagged == ["gone.example.com"],
               "expected exactly the stale record to be flagged; got #{inspect(flagged)} — " <>
                 "colouring more than is wrong teaches him that red means nothing"

        {:ok, context}
      end
    end
  end
end
