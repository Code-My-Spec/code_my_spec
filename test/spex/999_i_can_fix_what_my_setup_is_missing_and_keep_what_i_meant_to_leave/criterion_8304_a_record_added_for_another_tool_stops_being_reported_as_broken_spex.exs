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

  spex "A record added for another tool stops being reported as broken" do
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

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        view |> element("[data-test='start-setup']") |> render_click()
        # The run settling, not a step by name. This waited on `monitoring`,
        # a step removed from the sequence when it turned out to need an
        # account, an API key and a notification target only a person can
        # supply — so the wait could never succeed, spent its full thirty
        # seconds, and the criterion passed because thirty seconds is long
        # enough for the run to finish on its own.
        await_provisioning(view)

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
