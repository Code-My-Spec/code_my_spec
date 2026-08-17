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

  Surface: `CodeMySpecWeb.ResourceLive.Index` at `/app/resources`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Marking survives the resource list being rebuilt" do
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
        {:ok, view, _html} = live(context.conn, "/app/resources")
        render_async(view, 5_000)

        view
        |> element("[data-test='keep'][phx-value-location='storage/old-dumps']")
        |> render_click()

        {:ok, context}
      end

      when_ "the page re-reads every provider from scratch", context do
        # A fresh mount. Nothing carries over in the socket, so anything still
        # on the screen came back from storage rather than from memory.
        {:ok, view, _html} = live(context.conn, "/app/resources")

        {:ok, Map.put(context, :document, Floki.parse_document!(render_async(view, 5_000)))}
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
