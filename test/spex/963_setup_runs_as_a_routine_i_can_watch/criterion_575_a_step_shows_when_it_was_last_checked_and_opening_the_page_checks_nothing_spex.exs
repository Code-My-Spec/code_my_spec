defmodule CodeMySpecSpex.Story963.Criterion7970Spex do
  @moduledoc """
  Story 963 — Setup runs as a routine I can watch
  Criterion 7970 — A step shows when it was last checked, and opening the
  page checks nothing.

  Checks are manual only (John, 2026-10-02): mount reads the stored step
  row and renders it, with no provider call of its own. A step checked a
  week ago still reads "checked a week ago" when Sam opens the page later —
  not "just now", and not silently re-verified on the strength of a page
  load. This replaces the old claim (opening the page re-checks every done
  step against its provider), which mount no longer does at all.

  Observably: with the bucket long since checked, `refuse_verify_calls/0`
  makes any further provider check raise — so a page that tried to
  re-verify `:storage` on mount would crash it — and then opening the page
  must succeed and report how long ago that check was.

  Retargeted onto the console (provisioning-console-step6, unmerged): the
  manual-check model is unchanged — `StatusBadge` is reused as-is — so this
  just moves the mount and the step run onto the console's own routes and
  `run_console_step/2`.

  Surface: `CodeMySpecWeb.ConsoleLive` on the cloud app.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint
  @a_week_in_seconds 7 * 24 * 60 * 60

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :devops_on
  setup :fake_providers

  spex "A step shows when it was last checked, and opening the page checks nothing",
    criterion: 575 do
    scenario "opening the page later reports the old check, and calls nobody to get there" do
      given_ "the bucket step succeeded and was checked a week ago", context do
        {:ok, credentials_view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/console/credentials")

        paste_storage_credentials(credentials_view)

        {:ok, view, _html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/storage_backups?env=prod"
          )

        run_console_step(view, :storage)
        Fixtures.age_step_check(context.scope, :storage, "prod", @a_week_in_seconds)

        {:ok, context}
      end

      given_ "nothing may ask his provider about it again", context do
        refuse_verify_calls()

        {:ok, context}
      end

      when_ "Sam opens the status page later", context do
        {:ok, view, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/console/resources/storage_backups?env=prod"
          )

        {:ok, context |> Map.put(:view, view) |> Map.put(:html, html)}
      end

      then_ "opening the page never asks his provider about the step", context do
        assert Process.alive?(context.view.pid),
               "mount crashed — something called the provider despite the manual-check rule"

        {:ok, context}
      end

      then_ "the step still shows done, from the stored row rather than a fresh check", context do
        assert context.html =~ ~r/data-step="storage"[^>]*data-state="done"/,
               "expected the storage step to still read done without a fresh check"

        {:ok, context}
      end

      then_ "it reports when it was last checked, not when the page happened to open",
            context do
        assert has_element?(
                 context.view,
                 "[data-test='checked-note'][data-step='storage']"
               ),
               "expected the step to say when it was last checked"

        assert context.html =~ "checked 7d ago",
               "expected the stale check's own age, not a freshly re-verified one"

        {:ok, context}
      end
    end
  end
end
