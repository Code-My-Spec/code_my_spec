defmodule CodeMySpecSpex.Story974.Criterion2090Spex do
  @moduledoc """
  Story 974, criterion 657: inbound setup must ask before repointing
  a domain whose apex MX already sends mail to another provider.

  Surface: the cloud mail setup console and provider-backed DNS zone.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint
  @domain "astralbi.com"
  @existing_mx "mail.other-provider.example"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A domain already receiving mail elsewhere is not silently redirected",
    criterion: 657 do
    scenario "the existing provider stays in place until Sam chooses" do
      given_ "Sam's domain already has apex MX records pointing at another mail provider",
             context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        zone_record_exists(context, %{
          "type" => "MX",
          "name" => @domain,
          "content" => @existing_mx,
          "priority" => 10
        })

        before = apex_mx_records(zone_records(context))

        assert Enum.any?(before, &(&1["content"] == @existing_mx)),
               "expected mail to reach the existing provider before setup"

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/mail")

        {:ok, context |> Map.put(:view, view) |> Map.put(:before, before)}
      end

      when_ "the inbound step runs", context do
        run_console_step(context.view, :inbound)

        {:ok,
         context
         |> Map.put(:after, apex_mx_records(zone_records(context)))
         |> Map.put(:html, render(context.view))}
      end

      then_ "it does not delete or overwrite the existing MX records", context do
        assert context.after == context.before,
               "expected the other provider's apex MX records to remain unchanged"

        {:ok, context}
      end

      then_ "it names the conflict and asks Sam which provider should receive his mail",
            context do
        assert context.html =~ @existing_mx,
               "expected setup to name the provider currently receiving mail"

        assert has_element?(context.view, "[data-test='inbound-mx-repoint']"),
               "expected an explicit choice before repointing mail"

        {:ok, context}
      end

      then_ "the step does not report the inbox as done", context do
        assert context.html =~ ~r/data-step="inbound"[^>]*data-state="paused"/,
               "expected inbound setup to wait for Sam's decision"

        refute context.html =~ ~r/data-step="inbound"[^>]*data-state="done"/
        {:ok, context}
      end
    end
  end

  defp apex_mx_records(records) do
    records
    |> Enum.filter(&(&1["type"] == "MX" and &1["name"] in ["@", @domain]))
    |> Enum.sort_by(&{&1["name"], &1["content"]})
  end
end
