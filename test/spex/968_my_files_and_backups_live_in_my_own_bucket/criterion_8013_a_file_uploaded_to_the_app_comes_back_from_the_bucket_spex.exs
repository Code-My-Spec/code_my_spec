defmodule CodeMySpecSpex.Story968.Criterion8013Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8013 — A file uploaded to the app comes back from the bucket.

  The app is genuinely wired to Sam's bucket: a file uploaded through the
  app is stored there, and requesting it back returns the same file. A
  bucket that exists but that the app does not actually use is
  provisioning theatre.

  Round-trip, not just write — a spec that only asserted the PUT
  succeeded would pass against an app whose reads still hit local disk.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Hetzner`.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "hetzner_bucket_put_then_get_object"

  # The bucket has to exist before anything can be written to it, and the
  # given_ said so without doing it — the probe was writing into a bucket
  # nothing had created and failing with NoSuchBucket. Established through the
  # storage step rather than by reaching past the app, because that step is
  # what wires an app to its bucket.
  @setup_cassette "hetzner_bucket_create_for_probe"

  @body "round-trip-probe-contents"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A file uploaded to the app comes back from the bucket" do
    scenario "the object written through the app reads back identical" do
      given_ "the app is deployed and wired to its bucket", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        tear_down_after(context.scope, [:storage])

        # Pasting is inside the cassette because saving a credential now
        # proves it with a real call (criterion 7983) — it is a provider
        # interaction, not just a write.
        with_provider_cassette(@setup_cassette, fn ->
          paste_storage_credentials(view)

          view
          |> element("[data-test='setup-step'][data-step='storage'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam uploads a file through the app and requests it back", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> form("[data-test='storage-probe-form']",
              probe: %{environment: "prod", key: "round-trip.txt", body: @body}
            )
            |> render_submit()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the file was stored in his bucket", context do
        parsed = Floki.parse_document!(context.html)

        object =
          parsed
          |> Floki.find("[data-test='storage-object'][data-key='round-trip.txt']")

        # Anchor: the object was recorded as stored.
        assert object != [], "expected the uploaded object to be recorded"

        bucket = object |> Floki.attribute("data-bucket") |> List.first()

        assert is_binary(bucket) and bucket != "",
               "expected the object to name the bucket it landed in"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "requesting it back returns the same file", context do
        readback =
          context.parsed
          |> Floki.find("[data-test='storage-readback'][data-key='round-trip.txt']")

        assert readback != [], "expected the read-back to be recorded, not just the write"

        status = readback |> Floki.attribute("data-status") |> List.first()
        matches = readback |> Floki.attribute("data-matches-written") |> List.first()

        assert status == "200",
               "expected the object to be readable from the bucket, got #{inspect(status)}"

        assert matches == "true",
               "expected the bytes read back to match the bytes written"

        {:ok, context}
      end
    end
  end
end
