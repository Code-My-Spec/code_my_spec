defmodule CodeMySpecSpex.Story969.Criterion8029Spex do
  @moduledoc """
  Story 969 — My app sends mail from my own domain
  Criterion 8029 — Existing inbound mail survives the sending setup.

  If Sam already receives mail at his domain, publishing the sending
  records leaves that working. No record inbound delivery depends on is
  replaced — the bounce MX goes on the `send` subdomain, and apex MX is
  left exactly as it was.

  This is the paired constraint with story 974, which owns apex MX. Our own
  knowledge base warns against deleting apex MX blindly during a provider
  migration, and this is the spec that holds that line.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Resend`.

  ## Against fakes, not cassettes

  Rewritten 2026-08-16. The claim here is about *what we do* — that our
  publishing touches `send` and not `@` — and not about whether Cloudflare
  stores a record or a resolver can see it. A stateful fake answers that
  properly and a recording cannot: the assertion is a comparison of the zone
  before and after, which needs a provider that remembers the before.

  Under cassettes this criterion cost two live recordings and never replayed.
  The premise had to publish an apex MX for real, register a real domain, and
  read both back through a page whose mount made its own provider call — and
  the recording of all that went stale the moment any of those calls changed.
  Now the premise is one line of state, and the run is milliseconds.

  What is *not* claimed here, deliberately: that the published records
  resolve. That is a fact about the world and belongs to the drill.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Provisioning.Cloudflare

  @endpoint CodeMySpecWeb.Endpoint

  @domain "astralbi.com"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "Existing inbound mail survives the sending setup" do
    scenario "apex MX is untouched by publishing the sending records" do
      given_ "Sam already receives mail at his domain", context do
        own_domain(context.project, @domain)
        zone_exists(context, @domain)

        # The premise, stated rather than performed. Under cassettes this was a
        # real publish against a real zone, recorded — and the recording is
        # what went stale. Here it is the fact the criterion needs: an apex MX
        # exists, pointing at Sam's own mail host.
        {:ok, _} =
          Cloudflare.ensure_dns_record(context.scope, "zone-1", "@", "inbound.sams-host.net",
            type: "MX",
            priority: 10
          )

        {:ok, records} = Cloudflare.list_dns_records(context.scope, "zone-1")

        {:ok, Map.put(context, :before, records)}
      end

      when_ "the email step publishes its sending records", context do
        view = mount_provisioning(context)

        view
        |> element("[data-test='setup-step'][data-step='email'] [data-test='run-step']")
        |> render_click()

        CodeMySpecSpex.Case.await_step(view, :email)

        {:ok, records} = Cloudflare.list_dns_records(context.scope, "zone-1")

        {:ok, context |> Map.put(:view, view) |> Map.put(:after, records)}
      end

      then_ "the apex MX is exactly as it was", context do
        assert apex(context.after) == apex(context.before),
               "expected the apex MX to survive the sending setup:\n" <>
                 "  before: #{inspect(apex(context.before))}\n" <>
                 "  after:  #{inspect(apex(context.after))}"

        {:ok, context}
      end

      then_ "the sending records went on the send subdomain", context do
        added = context.after -- context.before

        refute added == [],
               "expected the email step to publish sending records, and it published none"

        refute Enum.any?(added, &(&1["name"] == "@")),
               "expected nothing published at the apex, got: #{inspect(names(added))}"

        {:ok, context}
      end
    end
  end

  defp apex(records), do: Enum.filter(records, &(&1["name"] == "@" and &1["type"] == "MX"))
  defp names(records), do: Enum.map(records, & &1["name"])
end
