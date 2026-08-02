defmodule CodeMySpecSpex.Story816.Criterion6590Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6590 — History survives past the provider's retention window.

  Rule: A mailbox retains its full email history independent of the
  provider's retention window.

  Surface:
    * `CodeMySpecWeb.MailLive` at "/app/projects/:project_id/mail" — an email persisted longer ago
      than the provider's (~30-day) retention window is still shown, because
      CMS persists its own copy.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  @domain "sam-ships.com"

  spex "Persisted history outlives the provider window" do
    scenario "History survives past the provider's retention window" do
      given_ "the support mailbox has an email older than the provider window", context do
        Fixtures.verify_project_domain(context.project, @domain)

        mailbox = Fixtures.mailbox_fixture(context.project, %{address: "support@#{@domain}"})

        Fixtures.persisted_email(mailbox, %{
          from: "lead@example.com",
          subject: "Old but important",
          body: "Sent months before today",
          inserted_at: ~U[2026-01-01 00:00:00Z]
        })

        {:ok, context}
      end

      when_ "Sam opens the mailbox", context do
        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mail")

        {:ok, _show_view, thread_html} =
          view
          |> element("[data-test='mailbox']", "support@#{@domain}")
          |> render_click()
          |> follow_redirect(context.conn)

        {:ok, Map.put(context, :thread_html, thread_html)}
      end

      then_ "the older email is still shown", context do
        assert context.thread_html =~ "Old but important",
               "expected persisted history to survive past the provider's retention window"

        {:ok, context}
      end
    end
  end
end
