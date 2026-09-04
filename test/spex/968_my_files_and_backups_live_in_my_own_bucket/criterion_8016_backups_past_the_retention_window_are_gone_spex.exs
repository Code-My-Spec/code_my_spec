defmodule CodeMySpecSpex.Story968.Criterion8016Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8016 — Backups past the retention window are gone.

  Dumps older than the retention window are no longer in the bucket, so
  Sam's storage bill does not grow without bound. Nightly dumps kept
  forever is a cost that compounds quietly for exactly as long as nobody
  looks.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app, driving
  `CodeMySpec.Provisioning.Hetzner`.
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

  spex "Backups past the retention window are gone" do
    scenario "no dump older than the retention window remains" do
      given_ "backups have been running longer than the retention window", context do
        # A bucket with a retention policy on it, and dumps in it. The
        # criterion is that old dumps are *gone*, which is indistinguishable
        # from "the bucket was always empty" unless the schedule genuinely
        # ran — mounting the page proved neither.
        view = mount_provisioning(context)

        # The backups step refuses on a project that is not deploy-ready, and it
        # is right to: a dump schedule on a project that cannot be deployed is a
        # schedule for nothing. Generating those files is what makes the premise
        # true (story 970).
        view |> element("[data-test='generate-project']") |> render_click()
        paste_storage_credentials(view)

        # The boxes first: `bin/backup` runs on the environment's own server,
        # and the server step is what mints the key that gets there.
        run_steps(view, [:server, :storage, :backups])

        # A dump from before the window, which is what "backups have been
        # running longer than the retention window" states. Without one the
        # assertion below has only this run's fresh dumps to look at and passes
        # whether or not anything expires them — which is the single thing this
        # criterion exists to check.
        old_dump_in_bucket(
          context,
          CodeMySpecSpex.Fixtures.bucket_name(context.project, "uat"),
          "uat",
          30
        )

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam lists the bucket", context do
        html =
          context.view
          |> element("[data-test='backups-refresh']")
          |> render_click()

        {:ok, Map.put(context, :html, html)}
      end

      then_ "dumps older than the window are no longer there", context do
        parsed = Floki.parse_document!(context.html)

        window_days =
          parsed
          |> Floki.find("[data-test='backup-retention']")
          |> Floki.attribute("data-days")
          |> List.first()

        # Anchor: a retention policy is declared, so "older than the window"
        # has a definition.
        assert is_binary(window_days) and window_days != "",
               "expected the retention window to be declared"

        stale =
          parsed
          |> Floki.find("[data-test='backup-dump']")
          |> Enum.filter(fn d ->
            (d |> Floki.attribute("data-age-days") |> List.first() || "0")
            |> String.to_integer()
            |> Kernel.>(String.to_integer(window_days))
          end)

        assert stale == [],
               "expected no dump older than #{window_days} days to remain, found #{length(stale)}"

        {:ok, Map.put(context, :parsed, parsed)}
      end

      then_ "the retention is enforced by the bucket rather than hoped for", context do
        enforced =
          context.parsed
          |> Floki.find("[data-test='backup-retention']")
          |> Floki.attribute("data-enforced-by")
          |> List.first()

        assert enforced in ["bucket_lifecycle", "expiry_policy"],
               "expected retention enforced by a bucket lifecycle policy rather than a script that might not run, got #{inspect(enforced)}"

        {:ok, context}
      end
    end
  end
end
