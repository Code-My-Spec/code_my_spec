defmodule CodeMySpecSpex.Story968.Criterion8017Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8017 — A dump restores into a working database.

  A dump in the bucket restores into an empty database, the restore
  completes, and the data that was in the source database is present. A
  file that cannot be restored is not a backup — it is a file.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  restore proof moved off ProvisioningLive's blocking click into
  storage_backups' Checks tab, behind DiagnosticsPanel, running async via
  `start_async` — same move criterion 613 made for the storage round-trip
  probe. `run_steps`/`mount_provisioning` are coupled to the old page's
  `setup-step` markup, so the three steps this needs are driven by hand
  instead.

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
  setup :real_backup_database
  setup :confirm_new_servers

  defp restore_done?(html),
    do: not (html =~ ~s(data-test="restore-probe" data-state="running"))

  spex "A dump restores into a working database", criterion: 617 do
    scenario "the restore completes and the source data is present" do
      given_ "a dump is in the bucket", context do
        # The dump under test has to exist. Restoring nothing into an
        # empty database succeeds trivially, so without this the `then_`
        # asserting "the source data is present" was the first thing to
        # notice, and it reads as a restore bug rather than a missing dump.
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

        # The server first: `bin/backup` runs on the environment's own box,
        # and the server step is what mints the key that gets there.
        {:ok, servers_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/resources/servers")

        servers_view
        |> element("[data-test='resource-step'][data-step='server'] [data-test='run-step']")
        |> render_click()

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/storage_backups"
          )

        view
        |> element("[data-test='resource-step'][data-step='storage'] [data-test='run-step']")
        |> render_click()

        view
        |> element("[data-test='resource-step'][data-step='backups'] [data-test='run-step']")
        |> render_click()

        view |> element("[data-test='resource-tab-checks']") |> render_click()

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it is restored into an empty database", context do
        context.view
        |> element("[data-test='backup-restore-probe']")
        |> render_click()

        html = await_operation(context.view, &restore_done?/1, &restore_done?/1)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the restore completes", context do
        restore =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='restore-result']")

        # Anchor: a restore was attempted and recorded.
        assert restore != [], "expected the restore attempt to be recorded"

        state = restore |> Floki.attribute("data-state") |> List.first()

        assert state == "succeeded",
               "expected the restore to complete, got #{inspect(state)}"

        {:ok, Map.put(context, :restore, restore)}
      end

      then_ "the data that was in the source database is present", context do
        rows = context.restore |> Floki.attribute("data-rows-restored") |> List.first()

        assert is_binary(rows),
               "expected the restore to report how much data came back"

        assert String.to_integer(rows) > 0,
               "expected a non-empty restore — a dump that restores zero rows proves nothing"

        verified = context.restore |> Floki.attribute("data-content-verified") |> List.first()

        assert verified == "true",
               "expected the restored contents to be checked, not just the exit status of pg_restore"

        {:ok, context}
      end
    end
  end
end
