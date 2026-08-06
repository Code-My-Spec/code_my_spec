defmodule CodeMySpecSpex.Story999.Criterion8305Spex do
  @moduledoc """
  Story 999 — I can fix what my setup is missing, and keep what I meant to leave
  Criterion 8305 — Trimming leaves a marked resource alone.

  The destructive half, and the reason marking had to exist before it. Trim
  deletes at the provider — a DNS record, a bucket with objects in it — and
  none of that comes back.

  Two claims, and the second is the stronger one. A marked resource survives
  the trim; and it is not offered for removal in the first place. Anything that
  relies on the delete path checking a flag has already put the marked resource
  in front of a button labelled "remove", one mis-click from gone. Keeping it
  out of the set is what makes the guarantee structural rather than careful.

  `Teardown.resource/3` already refuses anything whose origin is `adopted`,
  which is the same instinct one layer down: do not delete what you did not
  make. This is Sam's version of that judgement, for the things he did not make
  either.

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Trimming leaves a marked resource alone" do
    scenario "one dangling resource marked, one not" do
      given_ "a box setup once provisioned, since destroyed", context do
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
        await_step_state(view, "monitoring", "done")

        {:ok, context}
      end

      given_ "and two records still aimed at its address", context do
        owner = self()

        context =
          stage_inventory(
            context,
            %{
              hetzner: [],
              cloudflare: [
                inventory_resource(%{
                  kind: "dns_record",
                  location: "keep-me.example.com",
                  identifier: "A 203.0.113.99"
                }),
                inventory_resource(%{
                  kind: "dns_record",
                  location: "remove-me.example.com",
                  identifier: "A 203.0.113.99"
                })
              ],
              resend: [],
              storage: []
            }
          )

        # The delete seam. A criterion about *what gets deleted* must not
        # delete anything real to say so, and the message is the evidence.
        context = stage_trim(context, fn resource -> send(owner, {:trimmed, resource.location}) end)

        {:ok, view, _html} = live(context.conn, ~p"/app/resources")
        render_async(view)

        {:ok, Map.put(context, :view, view)}
      end

      given_ "one of which he has marked as deliberate", context do
        context.view
        |> element("[data-test='keep'][phx-value-location='keep-me.example.com']")
        |> render_click()

        {:ok, context}
      end

      when_ "he trims what is dangling", context do
        html = context.view |> element("[data-test='trim']") |> render_click()

        {:ok, context |> Map.put(:html, html) |> Map.put(:document, Floki.parse_document!(html))}
      end

      then_ "the unmarked one is removed at the provider", context do
        assert_received {:trimmed, "remove-me.example.com"},
                        "trim reported success without deleting the thing it was for"

        {:ok, context}
      end

      then_ "and the marked one is still there", context do
        refute_received {:trimmed, "keep-me.example.com"},
                        "a resource he explicitly said to keep was deleted at the provider, " <>
                          "and DNS records do not come back"

        {:ok, context}
      end

      then_ "and it was not offered for removal in the first place", context do
        # The stronger claim. A guarantee that depends on the delete path
        # checking a flag has already put the kept resource under a button
        # marked "remove".
        offered =
          context.document
          |> Floki.find("[data-test='trim-candidate']")
          |> Floki.attribute("data-location")

        refute "keep-me.example.com" in offered,
               "the kept resource was listed among the things trim would take, which is " <>
                 "one mis-click from irreversible"

        {:ok, context}
      end
    end
  end
end
