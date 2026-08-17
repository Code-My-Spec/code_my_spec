defmodule CodeMySpecSpex.Story816.Criterion6596Spex do
  @moduledoc """
  Story 816 — Sam sends and receives email on his own domain.
  Criterion 6596 — An admin syncs to recover mail the webhook missed.

  Rule: Inbound mail that the webhook missed can be reconciled on demand by
  syncing the project's mailboxes with the provider.

  Surface:
    * `CodeMySpecWeb.MailboxLive` at "/app/projects/:project_id/mailboxes" (owner/admin) — clicking
      Sync reconciles inbound mail against the provider's Receiving API,
      recording anything the webhook missed. The provider (Resend) list + body
      calls are replayed from recorded responses via `Req.Test` (shared mode).
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project
  setup :stub_resend

  @domain "sam-ships.com"

  spex "Syncing recovers inbound mail the webhook missed" do
    scenario "An admin syncs to recover mail the webhook missed" do
      given_ "a verified domain and a mailbox, with mail the project never recorded", context do
        Fixtures.verify_project_domain(context.project, @domain)
        mailbox = Fixtures.mailbox_fixture(context.project, %{address: "support@#{@domain}"})

        {:ok, view, _html} = live(context.conn, "/app/projects/#{context.project.id}/mailboxes")

        {:ok, Map.merge(context, %{view: view, mailbox: mailbox})}
      end

      when_ "the admin clicks Sync", context do
        context.view |> element("[data-test='sync-inbound']") |> render_click()

        {:ok, context}
      end

      then_ "the missed message is recorded and a count is shown", context do
        html = render(context.view)

        # The count, since that is what the step claims is shown. `html =~
        # "Synced"` passed on the word alone — it would have held for "Synced 0
        # message(s)", which is the one outcome this criterion exists to rule
        # out. The provider has exactly one message the project never recorded.
        assert html =~ "Synced 1 message(s) — 1 new",
               "expected the admin to see how many messages were synced, got:\n#{html}"

        # The recovered message now shows in the mailbox inbox.
        {:ok, _mail_view, mail_html} =
          live(context.conn, "/app/projects/#{context.project.id}/mail/#{context.mailbox.id}")

        assert mail_html =~ "Missed message",
               "expected the synced message to appear in the mailbox"

        {:ok, context}
      end
    end
  end

  # In the bridge: a spex may not read files, and the two recordings are
  # selected by the shape of the request rather than by branching on it.
  defp stub_resend(_context), do: Fixtures.stub_resend_receiving()
end
