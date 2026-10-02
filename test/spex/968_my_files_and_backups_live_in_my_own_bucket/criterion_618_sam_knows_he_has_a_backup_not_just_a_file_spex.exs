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

  Retargeted onto the console (provisioning-console-step6, unmerged): see
  criterion 613's moduledoc for the move — deploy file generation onto
  `/console/deploys`, credentials onto their own always-visible page, and
  the server/storage/backups steps onto their resource groups' Config
  tabs.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # The generated deploy files land on disk, and the backups step reads them.
  setup :fake_working_directory
  setup :fake_providers
  setup :fleet_backup_database
  setup :confirm_new_servers

  spex "Sam knows he has a backup, not just a file", criterion: 618 do
    scenario "the backup step proves a restore before it reports done" do
      given_ "the backup step has taken its first dump", context do
        # The bucket the dump lands in has to exist first. Without it the
        # backups step fails on missing storage, and the failure reads as
        # "restore verification broken" rather than "nowhere to write".
        {:ok, deploys_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/deploys")

        # The backups step refuses on a project that is not deploy-ready, and it
        # is right to: a dump schedule on a project that cannot be deployed is a
        # schedule for nothing. Generating those files is what makes the premise
        # true (story 970).
        deploys_view |> element("[data-test='generate-project']") |> render_click()

        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_storage_credentials(credentials_view)

        # Storage only: the backup step is what the `when_` runs, and
        # running it here too would make the criterion assert about a second
        # invocation rather than the first.
        # The server first: the dump runs on the environment's own box, and
        # the server step is what mints the key that gets there. Storage next,
        # because dumps land in the bucket it makes. Not backups — that is what
        # the `when_` runs, and running it here would make the criterion assert
        # about a second invocation rather than the first.
        {:ok, servers_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        run_console_step(servers_view, :server)

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/storage_backups"
          )

        run_console_step(view, :storage)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it verifies itself", context do
        html = run_console_step(context.view, :backups)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it restored that dump into a throwaway database and confirmed the data", context do
        parsed = Floki.parse_document!(context.html)

        proof =
          parsed
          |> Floki.find("[data-test='backup-restore-proof']")

        # Anchor: a proof was recorded, not merely a dump listing.
        assert proof != [],
               "expected the backup step to record a restore proof, backups step reads: " <>
                 (parsed
                  |> Floki.find("[data-step='backups']")
                  |> Floki.text()
                  |> String.replace(~r/\s+/, " ")
                  |> String.slice(0, 400))

        target = proof |> Floki.attribute("data-target") |> List.first()
        verified = proof |> Floki.attribute("data-content-verified") |> List.first()

        assert target =~ ~r/_restore_check$/,
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
          |> Floki.find("[data-test='resource-step'][data-step='backups']")
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
