defmodule CodeMySpecSpex.Story968.Criterion8054Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8054 — Sam knows he has a backup, not just a file.

  Setup does not call backups done until it has restored the first dump
  into a throwaway database and confirmed the data. Checking that a file
  landed with a plausible size is a guess; the failure shows up on the one
  day it matters.

  This is the gate criterion: 8017 says a restore *can* work, this says
  setup proves it before claiming the step is finished.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "backup_step_proves_restore_before_done"

  @given_cassette "968_8054_storage_ready"

  setup :register_log_in_setup_account
  setup :setup_active_project
  # The generated deploy files land on disk, and the backups step reads them.
  setup :real_working_directory
  setup :connect_providers
  setup :real_backup_database

  spex "Sam knows he has a backup, not just a file" do
    scenario "the backup step proves a restore before it reports done" do
      given_ "the backup step has taken its first dump", context do
        # The bucket the dump lands in has to exist first. Without it the
        # backups step fails on missing storage, and the failure reads as
        # "restore verification broken" rather than "nowhere to write".
        view = mount_provisioning(context)

        # The backups step refuses on a project that is not deploy-ready, and it
        # is right to: a dump schedule on a project that cannot be deployed is a
        # schedule for nothing. Generating those files is what makes the premise
        # true (story 970).
        view |> element("[data-test='generate-project']") |> render_click()
        paste_storage_credentials(view)

        # Storage only: the backup step is what the `when_` runs, and
        # running it here too would make the criterion assert about a second
        # invocation rather than the first.
        run_steps(view, [:storage], @given_cassette)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='setup-step'][data-step='backups'] [data-test='run-step']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it restored that dump into a throwaway database and confirmed the data", context do
        parsed = Floki.parse_document!(context.html)

        proof =
          parsed
          |> Floki.find("[data-test='backup-restore-proof']")

        # Anchor: a proof was recorded, not merely a dump listing.
        assert proof != [], "expected the backup step to record a restore proof"

        target = proof |> Floki.attribute("data-target") |> List.first()
        verified = proof |> Floki.attribute("data-content-verified") |> List.first()

        assert target == "scratch",
               "expected the restore to target a throwaway database rather than anything real, got #{inspect(target)}"

        assert verified == "true",
               "expected the restored data to be confirmed"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "only then is the step marked done", context do
        assert context.html =~ ~r/data-step="backups"[^>]*data-state="done"/,
               "expected the backup step to be done once the restore was proven"

        # The proof must precede the done state, not follow it — a step that
        # reports done and verifies afterwards has already lied once.
        proven_at =
          context.parsed
          |> Floki.find("[data-test='backup-restore-proof']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        done_at =
          context.parsed
          |> Floki.find("[data-test='setup-step'][data-step='backups']")
          |> Floki.attribute("data-completed-at")
          |> List.first()

        assert is_binary(proven_at) and is_binary(done_at),
               "expected both the proof and the step completion to be timestamped"

        assert proven_at <= done_at,
               "expected the restore proof to precede the step being called done: proven_at=#{proven_at} done_at=#{done_at}"

        {:ok, context}
      end
    end
  end
end
