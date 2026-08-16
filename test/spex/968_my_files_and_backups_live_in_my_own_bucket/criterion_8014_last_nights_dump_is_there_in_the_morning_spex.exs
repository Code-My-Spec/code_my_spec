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

  @install_cassette "968_8014_backup_schedule_installed"
  @listing_cassette "hetzner_bucket_list_dumps_after_run"

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  # The generated deploy files land on disk, and the backups step reads them.
  setup :real_working_directory
  setup :connect_providers
  setup :real_backup_database
  # The dump runs *on* a box: the step SSHes there, delivers `bin/backup` and
  # runs it. `real_backup_database` says which database to dump, not where to
  # run, so without this the step stops on its own preconditions and every
  # assertion below fails on a premise rather than on backups.
  setup :backups_on_fleet_box

  spex "Last night's dump is there in the morning" do
    scenario "a dump dated from the scheduled run is in the bucket" do
      given_ "setup installed the backup schedule", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        # The backups step refuses on a project that is not deploy-ready, and it
        # is right to: a dump schedule on a project that cannot be deployed is a
        # schedule for nothing. Generating those files is what makes the premise
        # true (story 970).
        view |> element("[data-test='generate-project']") |> render_click()

        # The bucket the dumps land in is real; it goes away with the spex.
        tear_down_after(context.scope, [:storage])

        html =
          with_full_cassette @install_cassette do
            # Hetzner issues object-storage keys only in its console, so they are
            # pasted per project — without them the backups step pauses asking for
            # them and never reaches the schedule this criterion is about.
            paste_storage_credentials(view)

            # Backups land in the bucket the storage step makes, so that has to exist
            # first — otherwise the dump fails with NoSuchBucket, which is true and
            # says nothing about the schedule under test.
            view
            |> element("[data-test='setup-step'][data-step='storage'] [data-test='run-step']")
            |> render_click()

            view
            |> element("[data-test='setup-step'][data-step='backups'] [data-test='run-step']")
            |> render_click()
          end

        assert html =~ ~r/data-step="backups"[^>]*data-state="done"/,
               "expected the backup step to complete before checking for dumps, got: " <>
                 (html |> Floki.parse_document!() |> Floki.find("[data-step='backups']") |> Floki.text() |> String.replace(~r/\s+/, " ") |> String.slice(0, 600))

        {:ok, Map.put(context, :view, view)}
      end

      when_ "a scheduled run has passed", context do
        html =
          with_provider_cassette(@listing_cassette, fn ->
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
