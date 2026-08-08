defmodule CodeMySpecSpex.Story968.Criterion8012Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8012 — Test data never lands in the production bucket.

  Each environment gets its own bucket, so a file uploaded while poking at
  UAT appears in the UAT bucket and the production bucket is untouched.
  Sharing one bucket across environments means test uploads mixed into
  real customer data with no way to tell them apart afterwards.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Hetzner`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @storage_cassette "hetzner_bucket_create_per_environment"
  @upload_cassette "hetzner_bucket_put_object_uat"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers

  spex "Test data never lands in the production bucket" do
    scenario "a file uploaded in UAT appears only in the UAT bucket" do
      given_ "both environments are set up with their own buckets", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        paste_storage_credentials(view)
        tear_down_after(context.scope, [:storage])

        html =
          with_provider_cassette(@storage_cassette, fn ->
            view
            |> element("[data-test='setup-step'][data-step='storage'] [data-test='run-step']")
            |> render_click()
          end)

        buckets_by_env =
          html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource'][data-kind='bucket']")
          |> Map.new(fn el ->
            {el |> Floki.attribute("data-environment") |> List.first(),
             el |> Floki.attribute("data-name") |> List.first()}
          end)

        # Anchor: separate buckets exist per environment, which is what makes
        # the isolation below possible at all.
        assert map_size(buckets_by_env) >= 2,
               "expected a bucket per environment, got #{inspect(buckets_by_env)}"

        refute buckets_by_env["uat"] == buckets_by_env["prod"],
               "expected UAT and production to have distinct buckets, both #{inspect(buckets_by_env["uat"])}"

        {:ok, context |> Map.put(:view, view) |> Map.put(:buckets, buckets_by_env)}
      end

      when_ "a file is uploaded in UAT", context do
        html =
          with_provider_cassette(@upload_cassette, fn ->
            context.view
            |> form("[data-test='storage-probe-form']",
              probe: %{environment: "uat", key: "probe.txt"}
            )
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it appears in the UAT bucket", context do
        objects = probe_objects(context.html)

        assert Enum.any?(objects, fn o -> o.environment == "uat" and o.key == "probe.txt" end),
               "expected the probe object in the UAT bucket, got #{inspect(objects)}"

        {:ok, Map.put(context, :objects, objects)}
      end

      then_ "the production bucket is untouched", context do
        refute Enum.any?(context.objects, fn o -> o.environment == "prod" end),
               "expected nothing written to the production bucket, got #{inspect(context.objects)}"

        {:ok, context}
      end
    end
  end

  defp probe_objects(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='storage-object']")
    |> Enum.map(fn el ->
      %{
        environment: el |> Floki.attribute("data-environment") |> List.first(),
        key: el |> Floki.attribute("data-key") |> List.first()
      }
    end)
  end
end
