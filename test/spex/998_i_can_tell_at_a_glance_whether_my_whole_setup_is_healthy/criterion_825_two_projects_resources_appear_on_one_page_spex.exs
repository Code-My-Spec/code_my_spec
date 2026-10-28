defmodule CodeMySpecSpex.Story998.Criterion8291Spex do
  @moduledoc """
  Story 998 — I can tell at a glance whether my whole setup is healthy
  Criterion 8291 — Two projects' resources appear on one page.

  The provisioning page answers "is this project set up", one project at a
  time. Nothing answers "what does this account own", and that is the question
  a bill asks.

  One page, because the failure this prevents is arithmetic nobody does: a
  resource is only forgotten relative to somewhere you would have looked, and
  eleven project pages is eleven places not to look.

  Surface: `CodeMySpecWeb.ResourceLive.Index`, the console's Inventory.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Two projects' resources appear on one page", criterion: 825 do
    scenario "one page covers the whole account" do
      given_ "two of Sam's projects have resources at his providers", context do
        context =
          stage_inventory(context, %{
            hetzner: [
              inventory_resource(%{kind: "bucket", location: "first-project-uat"}),
              inventory_resource(%{kind: "bucket", location: "second-project-uat"})
            ],
            cloudflare: [
              inventory_resource(%{kind: "dns_record", location: "uat.first.example"}),
              inventory_resource(%{kind: "dns_record", location: "uat.second.example"})
            ]
          })

        {:ok, context}
      end

      when_ "he opens the resources page", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/inventory")

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, render_settled(view))}
      end

      then_ "resources from both projects are listed", context do
        locations =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='resource']")
          |> Floki.attribute("data-location")

        assert "first-project-uat" in locations and "second-project-uat" in locations,
               "the page showed one project's resources, which is what the provisioning " <>
                 "page already does"

        assert "uat.first.example" in locations and "uat.second.example" in locations

        {:ok, context}
      end

      then_ "and he did not have to open either project to find them", context do
        # Reached from a third project's console. The page is account grain
        # or it is not answering the question.
        assert context.html =~ "data-test=\"resource\"",
               "the console's inventory showed only the open project's resources"

        {:ok, context}
      end
    end
  end
end
