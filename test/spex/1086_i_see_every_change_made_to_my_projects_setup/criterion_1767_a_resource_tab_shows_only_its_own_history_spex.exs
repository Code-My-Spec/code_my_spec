defmodule CodeMySpecSpex.Story1086.Criterion1767Spex do
  @moduledoc """
  Story 1086 — I see every change made to my project's setup
  Criterion 1767 — A resource tab shows only its own history.

  A storage question answered by scrolling past every DNS entry first is
  the problem this epic keeps finding in other shapes — the console's own
  per-resource Activity tab exists so a question about one resource stays
  a question about that resource. `ResourceGroups.for_step/1`'s key is
  what both the recorder and the reader key on, so there is one place that
  could let them drift, not two.

  Surface: `CodeMySpecWeb.ConsoleLive.Components.ResourceDetail` on the
  cloud app, driving `CodeMySpec.Activity`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "A resource tab shows only its own history", criterion: 1767 do
    scenario "the servers tab names nothing from DNS and domain" do
      given_ "a server step ran and a DNS step ran", context do
        context = scripted_run(context)

        {:ok, servers_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(servers_view, :server)

        {:ok, dns_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/dns_domain")

        run_console_step(dns_view, :dns)

        {:ok, context}
      end

      when_ "Sam opens the servers tab's own Activity", context do
        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/servers?tab=activity"
          )

        {:ok, Map.put(context, :document, Floki.parse_document!(render(view)))}
      end

      then_ "every entry shown ran the server step, never dns", context do
        entries = Floki.find(context.document, "[data-test='resource-activity-entry']")

        assert entries != [], "the servers tab's Activity never recorded the server step at all"

        text = Floki.text(entries)

        assert text =~ "server"

        refute text =~ "ran the dns step",
               "the servers tab is showing an entry that belongs to DNS and domain"

        {:ok, context}
      end
    end
  end
end
