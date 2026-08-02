defmodule CodeMySpecSpex.Story972.Criterion8036Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8036 — The post appears on the live site.

  End to end: the post Sam published renders at its address on his deployed
  site. Files in a bucket are not a blog — the criterion is satisfied by a
  page, not by an object listing.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "972_8036_content_publish_then_render_on_site"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "The post appears on the live site" do
    scenario "the published post renders at its address on the deployed site" do
      # Renamed from "Sam has published a post". It never published — it
      # wrote a file — and the publish is what the `when_` does. Naming the
      # precondition after the action under test is how a scenario reads as
      # covering two things while covering one.
      given_ "Sam has written a post in his repo", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\n---\n\nFirst post.\n"
          )

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he publishes, and the pipeline fetches its address on the deployed site", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='content-publish']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the post renders", context do
        render_check =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='content-render-check']")

        # Anchor: a render check was actually performed against the site.
        assert render_check != [], "expected the publish to verify the post rendered on the site"

        status = render_check |> Floki.attribute("data-status") |> List.first()
        path = render_check |> Floki.attribute("data-path") |> List.first()
        body_contains = render_check |> Floki.attribute("data-title-present") |> List.first()

        assert status == "200",
               "expected the post's address to answer 200 on the deployed site, got #{inspect(status)}"

        assert is_binary(path) and path =~ "hello",
               "expected the check to request the post's own address, got #{inspect(path)}"

        assert body_contains == "true",
               "expected the rendered page to actually contain the post, not merely answer 200"

        {:ok, context}
      end
    end
  end
end
