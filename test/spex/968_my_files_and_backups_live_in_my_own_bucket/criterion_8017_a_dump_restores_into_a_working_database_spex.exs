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

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A dump restores into a working database" do
    scenario "the restore completes and the source data is present" do
      given_ "a dump is in the bucket", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "it is restored into an empty database", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
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
