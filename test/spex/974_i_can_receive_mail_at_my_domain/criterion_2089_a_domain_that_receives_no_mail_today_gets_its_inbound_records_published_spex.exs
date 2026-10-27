defmodule CodeMySpecSpex.Story974.Criterion2089Spex do
  @moduledoc """
  Story 974, criterion 656: inbound setup publishes apex MX for a domain
  without mail while preserving the sending subdomain's records.

  Surface: the cloud mail setup console and the provider-backed DNS zone.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint
  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A domain that receives no mail today gets its inbound records published",
    criterion: 656 do
    scenario "inbound MX is added at the apex without changing sending records" do
      given_ "Sam's domain has no apex MX records", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/mail")

        run_console_step(view, :email)
        before = zone_records(context)

        refute Enum.any?(before, &apex_mx?/1),
               "expected the domain to have no apex MX before inbound setup"

        {:ok, context |> Map.put(:view, view) |> Map.put(:before, before)}
      end

      when_ "the inbound step runs", context do
        run_console_step(context.view, :inbound)

        {:ok,
         context |> Map.put(:after, zone_records(context)) |> Map.put(:html, render(context.view))}
      end

      then_ "it publishes the apex MX records inbound delivery needs", context do
        added_mx = Enum.filter(context.after -- context.before, &apex_mx?/1)

        assert added_mx != [],
               "expected inbound setup to publish apex MX, got #{inspect(context.after)}"

        {:ok, context}
      end

      then_ "the sending subdomains keep the records they already had", context do
        before = sending_records(context.before)
        assert before != [], "expected sending records to exist before inbound setup"

        assert sending_records(context.after) == before,
               "expected inbound setup to preserve sending records"

        {:ok, context}
      end
    end
  end

  defp apex_mx?(record),
    do: record["type"] == "MX" and record["name"] in ["@", @domain]

  defp sending_records(records) do
    records
    |> Enum.filter(&String.starts_with?(&1["name"], "send"))
    |> Enum.sort_by(&{&1["name"], &1["type"], &1["content"]})
  end
end
