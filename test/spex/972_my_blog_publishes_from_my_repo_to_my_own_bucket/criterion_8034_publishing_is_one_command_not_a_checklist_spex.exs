defmodule CodeMySpecSpex.Story972.Criterion8034Spex do
  @moduledoc """
  Story 972 — My blog publishes from my repo to my own bucket
  Criterion 8034 — Publishing is one command, not a checklist.

  Sam writes a post in his repo, runs one command, and it is published. No
  upload step, no cache purge, no "and then trigger the sync" — the whole
  point of wiring the pipeline during setup is that publishing afterwards
  is a single gesture.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.ContentPublishing`.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "content_publish_single_command"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Publishing is one command, not a checklist" do
    scenario "one publish action takes the post all the way out" do
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

      when_ "he runs the publish command", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='content-publish']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the post is published without any further step from him", context do
        publish =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='content-publish-result']")

        # Anchor: a publish actually ran.
        assert publish != [], "expected the publish to be recorded"

        state = publish |> Floki.attribute("data-state") |> List.first()

        assert state == "published",
               "expected the post to end up published, got #{inspect(state)}"

        {:ok, Map.put(context, :publish, publish)}
      end

      then_ "no follow-up action is left outstanding", context do
        pending =
          context.publish |> Floki.attribute("data-manual-steps-remaining") |> List.first()

        assert pending == "0",
               "expected nothing left for Sam to do after the one command, got #{inspect(pending)}"

        {:ok, context}
      end
    end
  end
end
