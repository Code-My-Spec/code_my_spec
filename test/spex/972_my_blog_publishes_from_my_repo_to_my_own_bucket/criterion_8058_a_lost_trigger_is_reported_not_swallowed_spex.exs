defmodule CodeMySpecSpex.Story972.Criterion8058Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8058 — A lost trigger is reported, not swallowed.

  Sync is trigger-only — Sam's decision — with no scheduled reconciliation
  pass. That makes this criterion load-bearing rather than a nicety: if the
  trigger fails to land, nothing else will ever notice, so the publish
  command itself must tell him. Otherwise he is left believing a post is
  live when it is sitting unseen in a bucket.

  This scenario replaced an earlier one asserting a missed trigger
  self-heals, which trigger-only sync makes false.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "content_publish_trigger_unreachable"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "A lost trigger is reported, not swallowed" do
    scenario "a publish whose trigger cannot land reports the failure" do
      given_ "Sam publishes while his site cannot be reached", context do
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

      when_ "the trigger fails to land", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='content-publish']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Sam is told the publish did not reach the site", context do
        parsed = Floki.parse_document!(context.html)

        result = parsed |> Floki.find("[data-test='content-publish-result']")

        # Anchor: a publish result was reported at all.
        assert result != [], "expected the publish to report a result"

        state = result |> Floki.attribute("data-state") |> List.first()

        assert state in ["trigger_failed", "failed"],
               "expected the publish to report the trigger failure, got #{inspect(state)}"

        text = parsed |> Floki.find("[data-test='content-publish-error']") |> Floki.text()

        assert text =~ ~r/trigger|unreachable|did not reach/i,
               "expected the message to say the trigger did not land, got: #{inspect(text)}"

        {:ok, Map.put(context, :result, result)}
      end

      then_ "he is not left believing the post is live", context do
        refute context.html =~ ~r/data-test="content-publish-result"[^>]*data-state="published"/,
               "expected the publish not to report success when the trigger never landed"

        # Trigger-only sync means nothing will retry on its own, so the
        # report must say the objects are uploaded but unserved.
        uploaded = context.result |> Floki.attribute("data-objects-uploaded") |> List.first()

        assert uploaded == "true",
               "expected the report to distinguish uploaded-but-unserved from not-uploaded, so Sam knows a re-trigger is all that is needed"

        {:ok, context}
      end
    end
  end
end
