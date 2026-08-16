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

  ## Against fakes, and a refusal at the layer that refuses

  Rewritten 2026-08-16. The old version said it was "the only criterion in 972
  still running live, and for a reason that is not laziness: its subject is a
  trigger that never lands, and a recorder has nowhere to put 'connection
  refused'". That reasoning was right about the trigger and wrong about the
  rest — the *upload* half still wanted the fleet's MinIO, so the criterion
  only ran where somebody had the fleet up.

  The upload now goes to the storage fake, and the trigger fails as a transport
  error, which is what an unreachable site is. Pointing the client at a closed
  port reads as more honest and is not reachable: `config/test.exs` pins every
  client to `Req.Test`, so the request never leaves and raises `no mock or
  stub` instead of connecting.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers
  setup :trigger_unreachable

  spex "A lost trigger is reported, not swallowed" do
    scenario "a publish whose trigger cannot land reports the failure" do
      given_ "Sam publishes while his site cannot be reached", context do
        :ok =
          Environments.write_file(
            context.environment,
            "content/posts/hello.md",
            "---\ntitle: Hello\ntype: blog\n---\n\nFirst post.\n"
          )

        # Storage is the fake; the trigger refuses at the transport layer.
        # Both halves used to need the fleet, which is why this ran on one
        # machine.
        project =
          publishable_project(context.scope, context.project, %{
            content_bucket: "sams-content",
            deploy_key: "dk-spex",
            client_api_url: "https://sams-site.example.com"
          })

        context =
          context
          |> Map.put(:project, project)
          |> Map.put(:scope, %{context.scope | active_project: project})

        {:ok, Map.put(context, :view, mount_provisioning(context))}
      end

      when_ "the trigger fails to land", context do
        # The publish command itself. The setup step's run button wires the
        # pipeline up and leaves the publish result unset, so the reported
        # failure this criterion is about was never rendered to read.
        context.view
        |> element("[data-test='content-publish']")
        |> render_click()

        {:ok, Map.put(context, :html, render(context.view))}
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

        assert text =~ ~r/trigger|unreachable|did not reach|refused/i,
               "expected the message to say the trigger did not land, got: #{inspect(text)}"

        {:ok, Map.put(context, :result, result)}
      end

      then_ "he is not left believing the post is live", context do
        refute context.html =~ ~r/data-test="content-publish-result"[^>]*data-state="published"/,
               "expected the publish not to report success when the trigger never landed"

        {:ok, context}
      end
    end
  end
end
