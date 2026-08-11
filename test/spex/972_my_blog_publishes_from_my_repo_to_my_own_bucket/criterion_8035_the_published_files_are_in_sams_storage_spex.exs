defmodule CodeMySpecSpex.Story972.Criterion8035Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8035 — The published files are in Sam's storage.

  A published post's files land in Sam's own content bucket, in his own
  account — not in platform-owned storage he loses access to if he leaves.
  The pipeline itself was built by stories 712/713; this is about it
  pointing at his infrastructure rather than ours.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "content_publish_objects_in_user_bucket"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers
  # A publish refuses outright without content_bucket, client_api_url and
  # deploy_key — "Publishing is not configured" — so the step never reaches
  # storage and the criterion reads that as nothing having been written.
  setup :publishing_configured

  spex "The published files are in Sam's storage" do
    scenario "the published objects are recorded in Sam's own bucket" do
      given_ "Sam has published a post", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\n---\n\nFirst post.\n"
          )

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        html =
          with_provider_cassette(@cassette, fn ->
            view |> element("[data-test='content-publish']") |> render_click()
          end)

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      when_ "he lists his content bucket", context do
        objects =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='content-object']")

        {:ok, Map.put(context, :objects, objects)}
      end

      then_ "the post's files are there in his own account", context do
        # Anchor: objects were published at all.
        assert context.objects != [], "expected the publish to record the objects it wrote"

        for object <- context.objects do
          owner = object |> Floki.attribute("data-owner") |> List.first()
          bucket = object |> Floki.attribute("data-bucket") |> List.first()

          assert owner == "user",
                 "expected published objects to live in Sam's own account, got #{inspect(owner)}"

          assert is_binary(bucket) and bucket != "",
                 "expected each object to name the bucket it landed in"
        end

        {:ok, context}
      end

      then_ "nothing was published into platform storage", context do
        refute context.html =~ ~r/data-test="content-object"[^>]*data-owner="platform"/,
               "expected no published content held in platform-owned storage"

        {:ok, context}
      end
    end
  end
end
