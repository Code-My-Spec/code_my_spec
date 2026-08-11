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

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :connect_providers
  # A publish refuses outright without content_bucket, client_api_url and
  # deploy_key — "Publishing is not configured" — so the step never reaches
  # storage and the criterion reads that as nothing having been written.
  setup :publishing_to_the_fleet

  spex "A lost trigger is reported, not swallowed" do
    scenario "a publish whose trigger cannot land reports the failure" do
      given_ "Sam publishes while his site cannot be reached", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\n---\n\nFirst post.\n"
          )

        # The unreachable site is the whole premise, and nothing here was
        # establishing it — the fleet site the other criteria publish to is up,
        # so the trigger landed and the publish reported "published". Storage
        # stays on the fleet; only the client the trigger POSTs to moves to a
        # closed port, which is the failure this criterion is about.
        # Storage has to stay on the fleet explicitly: these attrs are merged
        # over the helper's own defaults, which point at real object storage,
        # so overriding the client alone put the bucket back on Hetzner and the
        # publish failed in S3 with a 403 before it ever reached a trigger.
        project =
          publishable_project(context.scope, context.project, %{
            content_bucket: "cms-spex-content",
            s3_endpoint: "http://127.0.0.1:9000",
            aws_access_key_id: "cms-fleet",
            aws_secret_access_key: "cms-fleet-secret",
            aws_region: "us-east-1",
            deploy_key: "dk_fleet_spex",
            client_api_url: "http://127.0.0.1:9"
          })

        context =
          context
          |> Map.put(:project, project)
          |> Map.put(:scope, %{context.scope | active_project: project})

        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the trigger fails to land", context do
        # The step, run against the fleet: MinIO for storage, the generated site
        # on loopback for the trigger and the render check. No cassette — the
        # claims here are that objects landed in a bucket and a post came back
        # from a site, and a recording answers both from a file whatever the code
        # did.
        # The publish command itself. The setup step's run button wires the
        # pipeline up and leaves the publish result unset, so the reported
        # failure this criterion is about was never rendered to read.
        context.view
        |> element("[data-test='content-publish']")
        |> render_click()

        html = render(context.view)

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
