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

  @cassette "hetzner_bucket_list_dumps_after_expiry"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Backups past the retention window are gone" do
    scenario "no dump older than the retention window remains" do
      given_ "backups have been running longer than the retention window", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/provisioning")

        {:ok, Map.put(context, :view, view)}
      end

      when_ "Sam lists the bucket", context do
        html =
          ReqCassette.with_cassette(@cassette, [mode: :replay], fn ->
            context.view
            |> element("[data-test='backups-refresh']")
            |> render_click()
          end)

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
