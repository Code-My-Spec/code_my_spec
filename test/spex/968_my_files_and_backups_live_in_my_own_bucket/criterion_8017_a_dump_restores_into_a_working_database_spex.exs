defmodule CodeMySpecSpex.Story968.Criterion8017Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8017 — A dump restores into a working database.

  A dump in the bucket restores into an empty database, the restore
  completes, and the data that was in the source database is present. A
  file that cannot be restored is not a backup — it is a file.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @cassette "backup_restore_into_scratch_db"

  @given_cassette "968_8017_dump_taken"

  setup :register_log_in_setup_account
  setup :setup_active_project
  # The generated deploy files land on disk, and the backups step reads them.
  setup :real_working_directory
  setup :connect_providers
  setup :real_backup_database

  spex "A dump restores into a working database" do
    scenario "the restore completes and the source data is present" do
      given_ "a dump is in the bucket", context do
        # The dump under test has to exist. Restoring nothing into an
        # empty database succeeds trivially, so without this the `then_`
        # asserting "the source data is present" was the first thing to
        # notice, and it reads as a restore bug rather than a missing dump.
        view = mount_provisioning(context)

        # The backups step refuses on a project that is not deploy-ready, and it
        # is right to: a dump schedule on a project that cannot be deployed is a
        # schedule for nothing. Generating those files is what makes the premise
        # true (story 970).
        view |> element("[data-test='generate-project']") |> render_click()
        paste_storage_credentials(view)

        run_steps(view, [:storage, :backups], @given_cassette)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it is restored into an empty database", context do
        html =
          with_provider_cassette(@cassette, fn ->
            context.view
            |> element("[data-test='backup-restore-probe']")
            |> render_click()
          end)

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
