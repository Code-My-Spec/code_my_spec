defmodule CodeMySpecSpex.Story963.Criterion7969Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7969 — Sam reads back what he now owns.

  When setup finishes, Sam can read back each provisioned resource and
  where it lives, and find every one of them in his own provider
  consoles. A routine that provisions infrastructure without telling him
  what it made leaves him unable to audit, bill, or clean up.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "setup_full_run_ok"
  @given_cassette "963_7969_credentials"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :connect_providers

  spex "Sam reads back what he now owns" do
    scenario "the record lists each provisioned resource and where it lives" do
      given_ "setup has completed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # Hetzner has no OAuth, so its token is pasted per project — without it
        # the server step stops at `hetzner_not_configured` and every claim
        # downstream fails for a reason that is not the one under test. Saving a
        # credential proves it with a real provider call, so it belongs inside a
        # cassette.
        tear_down_after(context.scope, [:server])

        # The repository too, so the next recording starts from one that does not
        # exist — a repository carrying an earlier run's commits rejects a fresh
        # push as non-fast-forward (which is 8184's subject, not this one's).
        tear_down_repository(context.project)

        # The repository an earlier recording made still exists, so setup would
        # pause asking whose it is. It is this project's — stating that lets the
        # run reach the steps under test.
        own_repository(context.project)

        with_provider_cassette(@given_cassette, fn ->
          paste_provider_credentials(view)
        end)

        with_provider_cassette(@cassette, fn ->
          view |> element("[data-test='start-setup']") |> render_click()

          # The repository an earlier recording made cannot be deleted (the grant
          # has no `delete_repo` scope), so the run pauses on the name and every
          # step under test stays not_started. Adopting is the honest answer.
          adopt_repository_if_paused(view)
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam opens the setup record", context do
        html =
          context.view
          |> element("[data-test='setup-record']")
          |> render()

        {:ok, Map.put(context, :record, html)}
      end

      then_ "he sees each provisioned resource and where it lives", context do
        resources =
          context.record
          |> Floki.parse_document!()
          |> Floki.find("[data-test='provisioned-resource']")

        # Anchor: the record listed anything at all.
        assert resources != [], "expected the setup record to list provisioned resources"

        for resource <- resources do
          kind = resource |> Floki.attribute("data-kind") |> List.first()
          location = resource |> Floki.attribute("data-location") |> List.first()

          assert is_binary(kind) and kind != "",
                 "expected every recorded resource to name what it is"

          assert is_binary(location) and location != "",
                 "expected #{kind} to record where it lives so Sam can find it in his console"
        end

        {:ok, context}
      end
    end
  end
end
