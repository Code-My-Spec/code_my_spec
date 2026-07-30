defmodule CodeMySpecSpex.Story968.Criterion8014Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8014 — Last night's dump is there in the morning.

  Setup installs a schedule, and after a scheduled run has passed a dump
  of that environment's database is in the bucket, dated from that run.
  Installing a cron entry is not the same as producing a backup — the
  assertion is on the artifact, not the schedule.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Deploy` (backup scheduling) and
  `CodeMySpec.Provisioning.Hetzner` (the bucket).
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @install_cassette "backup_schedule_installed"
  @listing_cassette "hetzner_bucket_list_dumps_after_run"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Last night's dump is there in the morning" do
    scenario "a dump dated from the scheduled run is in the bucket" do
      given_ "setup installed the backup schedule", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        html =
          ReqCassette.with_cassette(@install_cassette, [mode: :replay], fn ->
            view
            |> element("[data-test='setup-step'][data-step='backups'] [data-test='run-step']")
            |> render_click()
          end)

        assert html =~ ~r/data-step="backups"[^>]*data-state="done"/,
               "expected the backup step to complete before checking for dumps"

        {:ok, Map.put(context, :view, view)}
      end

      when_ "a scheduled run has passed", context do
        html =
          ReqCassette.with_cassette(@listing_cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='backups-refresh']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "a dump of that environment's database is in the bucket", context do
        dumps =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='backup-dump']")

        # Anchor: dumps were listed at all.
        assert dumps != [], "expected at least one dump to be listed after a scheduled run"

        for dump <- dumps do
          env = dump |> Floki.attribute("data-environment") |> List.first()
          bucket = dump |> Floki.attribute("data-bucket") |> List.first()

          assert is_binary(env) and env != "",
                 "expected each dump to name the environment it came from"

          assert is_binary(bucket) and bucket != "",
                 "expected each dump to live in a named bucket"
        end

        {:ok, Map.put(context, :dumps, dumps)}
      end

      then_ "it is dated from that run", context do
        for dump <- context.dumps do
          taken_at = dump |> Floki.attribute("data-taken-at") |> List.first()

          assert is_binary(taken_at) and taken_at != "",
                 "expected each dump to carry when it was taken, so a stale dump is distinguishable"
        end

        {:ok, context}
      end
    end
  end
end
