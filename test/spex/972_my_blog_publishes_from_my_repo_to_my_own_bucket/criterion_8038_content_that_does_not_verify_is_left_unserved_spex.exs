defmodule CodeMySpecSpex.Story972.Criterion8038Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8038 — Content that does not verify is left unserved.

  A published file that arrives at the site but fails verification is not
  served, and visitors keep seeing the previously good version. Serving
  unverified content would mean a corrupted or truncated publish silently
  replacing a working page.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @good_cassette "972_8038_content_publish_then_render_on_site"
  @bad_cassette "content_publish_verification_fails"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers
  # A publish refuses outright without content_bucket, client_api_url and
  # deploy_key — "Publishing is not configured" — so the step never reaches
  # storage and the criterion reads that as nothing having been written.
  setup :publishing_to_the_fleet

  spex "Content that does not verify is left unserved" do
    scenario "a failing verification leaves the previous version serving" do
      given_ "a good version of the post is already live", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\ntype: blog\n---\n\nGood version.\n"
          )

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        before =
          with_provider_cassette(@good_cassette, fn ->
            view |> element("[data-test='content-publish']") |> render_click()
          end)

        # Anchor: something good was serving before the bad publish.
        assert before =~ ~r/data-test="content-render-check"[^>]*data-status="200"/,
               "expected a good version to be live before the failing publish"

        {:ok, context |> Map.put(:view, view) |> Map.put(:served_before, served_version(before))}
      end

      when_ "a published file arrives but does not verify", context do
        html =
          with_provider_cassette(@bad_cassette, fn ->
            context.view |> element("[data-test='content-publish']") |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it is not served to visitors", context do
        parsed = Floki.parse_document!(context.html)

        verification =
          parsed |> Floki.find("[data-test='content-verification']")

        assert verification != [], "expected the verification result to be recorded"

        state = verification |> Floki.attribute("data-state") |> List.first()

        assert state == "failed",
               "expected verification to have failed, got #{inspect(state)}"

        served = verification |> Floki.attribute("data-served") |> List.first()

        assert served == "false",
               "expected unverified content not to be served, got #{inspect(served)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "the previously good version is still what they see", context do
        assert served_version(context.html) == context.served_before,
               "expected the live version to be unchanged by a failed publish:\n  before: #{inspect(context.served_before)}\n  after:  #{inspect(served_version(context.html))}"

        {:ok, context}
      end
    end
  end

  defp served_version(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("[data-test='content-served-version']")
    |> Floki.attribute("data-version")
    |> List.first()
  end
end
