defmodule CodeMySpecSpex.Story968.Criterion8015Spex do
  @moduledoc """
  Story 968 — My files and backups live in my own bucket
  Criterion 8015 — A backup that stops running does not fail silently.

  When the scheduled dump has failed for several nights, Sam can see that
  backups are not landing — he is not left believing he has backups he
  does not have. A silently broken backup is worse than no backup, because
  it removes the pressure to check.

  Surface: `CodeMySpecWeb.ProvisioningLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  @install_cassette "backup_schedule_installed"
  @stalled_cassette "hetzner_bucket_list_dumps_stale"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A backup that stops running does not fail silently" do
    scenario "stalled backups are visible rather than assumed healthy" do
      given_ "the backup schedule was installed", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        ReqCassette.with_cassette(@install_cassette, [mode: :replay], fn ->
          view
          |> element("[data-test='setup-step'][data-step='backups'] [data-test='run-step']")
          |> render_click()
        end)

        {:ok, Map.put(context, :view, view)}
      end

      when_ "the scheduled dump has failed for several nights", context do
        html =
          ReqCassette.with_cassette(@stalled_cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='backups-refresh']")
            |> render_click()
          end)

        {:ok, Map.put(context, :html, html)}
      end

      then_ "Sam can see that backups are not landing", context do
        health =
          context.html
          |> Floki.parse_document!()
          |> Floki.find("[data-test='backup-health']")

        # Anchor: a health indicator exists at all.
        assert health != [], "expected the page to report backup health"

        state = health |> Floki.attribute("data-state") |> List.first()

        assert state == "stalled",
               "expected backups to read as stalled when dumps stop landing, got #{inspect(state)}"

        {:ok, Map.put(context, :health, health)}
      end

      then_ "he is not left believing he has backups he does not have", context do
        refute context.html =~ ~r/data-test="backup-health"[^>]*data-state="healthy"/,
               "expected backups not to read healthy while dumps are missing"

        last_seen = context.health |> Floki.attribute("data-last-successful-at") |> List.first()

        assert is_binary(last_seen),
               "expected the page to say when a backup last actually succeeded, not merely that a schedule exists"

        {:ok, context}
      end
    end
  end
end
