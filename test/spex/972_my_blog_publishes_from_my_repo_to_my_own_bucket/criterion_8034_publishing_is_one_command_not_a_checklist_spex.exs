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

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers
  setup :publishing_to_the_fleet

  spex "Publishing is one command, not a checklist" do
    scenario "one publish action takes the post all the way out" do
      given_ "Sam has written a post in his repo", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\n---\n\nFirst post.\n"
          )

        # Somewhere to publish to is part of the premise — sync is trigger-only,
        # so without a bucket and a reachable client the publish refuses to
        # start and this fails on its setup rather than its claim. That is
        # `publishing_to_the_fleet` above, as it is for every other criterion in
        # this story; this one alone pointed at real object storage and got
        # `403 InvalidAccessKeyId` back from Hetzner. The fleet bucket is
        # standing infrastructure shared with those siblings, so it is not torn
        # down here.
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "he runs the publish command", context do
        # The step, run against the fleet: MinIO for storage, the generated site
        # on loopback for the trigger and the render check. No cassette — the
        # claims here are that objects landed in a bucket and a post came back
        # from a site, and a recording answers both from a file whatever the code
        # did.
        # The publish command, not the setup step that wires the pipeline up.
        # Clicking the step's run button provisions the bucket and leaves
        # `@content_publish` unset, so the result this criterion reads on was
        # never rendered and the failure read as "no publish happened".
        context.view
        |> element("[data-test='content-publish']")
        |> render_click()

        html = render(context.view)

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

        # The page renders why a publish failed; reading it back means the
        # failure names its cause instead of just its state.
        reason = publish |> Floki.text() |> String.trim()

        assert state == "published",
               "expected the post to end up published, got #{inspect(state)}: #{reason}"

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
