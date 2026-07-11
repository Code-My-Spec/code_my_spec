defmodule CodeMySpecWeb.MailLive do
  @moduledoc """
  The operator's mail inbox — a Gmail-style two-pane client over the project's
  mailboxes. The left rail lists the mailboxes the current member may see
  (role-scoped: owners/admins see all, members see shared + their own). The
  main area shows either the **conversation list** for the open mailbox (one
  row per thread: correspondent, subject + snippet, time) or, when a row is
  opened, the **conversation** itself (stacked messages with a Reply action).
  Composing and replying happen in modal dialogs.

  Administering mailboxes (creating them, domain setup) lives on the separate
  owner/admin-only `CodeMySpecWeb.MailboxLive`.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Mail
  alias CodeMySpec.Mail.{HtmlSanitizer, ImageProxy}
  alias CodeMySpec.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Mail")
     |> assign(:domain_verified?, Project.domain_verified?(scope.active_project))
     |> assign(:can_administer?, Mail.can_administer?(scope))
     |> assign(:mailboxes, Mail.list_mailboxes(scope))
     |> assign(:mailbox, nil)
     |> assign(:threads, [])
     |> assign(:selected, nil)
     |> assign(:current_thread, nil)
     |> assign(:modal, nil)}
  end

  @impl true
  def handle_params(%{"id" => id} = params, _uri, %{assigns: %{live_action: :show}} = socket) do
    mailbox = Mail.get_mailbox(socket.assigns.current_scope, id)
    threads = if mailbox, do: Mail.list_threads(mailbox), else: []
    key = params["thread"]
    current = key && Enum.find(threads, &(&1.key == key))

    {:noreply,
     socket
     |> assign(:mailbox, mailbox)
     |> assign(:threads, threads)
     |> assign(:selected, key)
     |> assign(:current_thread, current)
     |> assign(:page_title, (mailbox && mailbox.address) || "Mail")}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:mailbox, nil)
     |> assign(:threads, [])
     |> assign(:selected, nil)
     |> assign(:current_thread, nil)}
  end

  @impl true
  def handle_event("open_mailbox", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/app/mail/#{id}")}
  end

  # Thread selection lives in the URL (?thread=KEY) so a reload stays on the
  # open conversation. The event just patches the URL; handle_params opens it.
  def handle_event("open_thread", %{"key" => key}, socket) do
    {:noreply, push_patch(socket, to: thread_path(socket.assigns.mailbox, key))}
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply, push_patch(socket, to: thread_path(socket.assigns.mailbox, nil))}
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, assign(socket, :modal, String.to_existing_atom(modal))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  # Owner/admins can pull any inbound the webhook missed straight from the
  # provider (the catch-up companion to the at-least-once webhook).
  def handle_event("sync", _params, socket) do
    scope = socket.assigns.current_scope

    socket =
      if Mail.can_administer?(scope) do
        case Mail.sync_inbound(scope.active_project) do
          {:ok, %{new: new, backfilled: back}} ->
            socket
            |> refresh_threads()
            |> put_flash(:info, "Synced — #{new} new, #{back} updated.")

          {:error, _reason} ->
            put_flash(socket, :error, "Couldn't reach the mail provider to sync.")
        end
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("compose", %{"email" => %{"to" => to, "subject" => subject, "body" => body}}, socket) do
    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{to: to, subject: subject, body: body})

    key = latest_thread_key(socket.assigns.mailbox)
    {:noreply, socket |> assign(:modal, nil) |> push_patch(to: thread_path(socket.assigns.mailbox, key))}
  end

  def handle_event("reply", %{"email" => %{"to" => to, "body" => body}}, socket) do
    subject = reply_subject(socket.assigns.current_thread)

    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{to: to, subject: subject, body: body})

    key = latest_thread_key(socket.assigns.mailbox)
    {:noreply, socket |> assign(:modal, nil) |> push_patch(to: thread_path(socket.assigns.mailbox, key))}
  end

  defp latest_thread_key(mailbox) do
    mailbox |> Mail.list_threads() |> List.first() |> then(&(&1 && &1.key))
  end

  # Re-read the open mailbox's threads (and the open thread) after a change.
  defp refresh_threads(%{assigns: %{mailbox: nil}} = socket), do: socket

  defp refresh_threads(%{assigns: %{mailbox: mailbox, selected: key}} = socket) do
    threads = Mail.list_threads(mailbox)

    socket
    |> assign(:threads, threads)
    |> assign(:current_thread, key && Enum.find(threads, &(&1.key == key)))
  end

  defp thread_path(mailbox, nil), do: ~p"/app/mail/#{mailbox.id}"
  defp thread_path(mailbox, key), do: ~p"/app/mail/#{mailbox.id}?thread=#{key}"

  defp reply_subject(%{subject: subject}) when is_binary(subject), do: prefix_re(subject)
  defp reply_subject(_), do: "Re:"

  defp prefix_re("Re:" <> _ = subject), do: subject
  defp prefix_re(subject), do: "Re: #{subject}"

  defp assigned_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp assigned_label(_mailbox), do: "Shared"

  defp sender_label(:outbound), do: "You"
  defp sender_label(_direction), do: "Them"

  defp format_at(nil), do: ""
  defp format_at(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %-I:%M %p")

  # Compact, relative-ish stamp for list rows (today → time, else date).
  defp short_at(nil), do: ""

  defp short_at(%DateTime{} = at) do
    now = DateTime.utc_now()

    if DateTime.to_date(at) == DateTime.to_date(now),
      do: Calendar.strftime(at, "%-I:%M %p"),
      else: Calendar.strftime(at, "%b %-d")
  end

  # First line of the thread's latest message, for the list-row preview. Falls
  # back to text stripped from the HTML body when there's no plain-text part.
  defp snippet(%{emails: emails}) do
    case List.last(emails) do
      %{body_text: body} when is_binary(body) and body != "" ->
        clip(body)

      %{body_html: html} when is_binary(html) and html != "" ->
        html |> HtmlSanitizer.to_text() |> clip()

      _ ->
        ""
    end
  end

  defp clip(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 140)
  end

  # Prefer the sanitized HTML body; only render text when there's no HTML.
  defp render_body(%{body_html: html}) when is_binary(html) and html != "" do
    {:html, HtmlSanitizer.sanitize(html, rewrite_img: &ImageProxy.signed_path/1)}
  end

  defp render_body(%{body_text: text}) when is_binary(text), do: {:text, text}
  defp render_body(_), do: {:text, ""}

  defp thread_has_attachments?(%{emails: emails}) do
    Enum.any?(emails, fn e -> match?([_ | _], e.attachments) end)
  end

  defp attachments(%{attachments: list}) when is_list(list), do: list
  defp attachments(_), do: []

  defp format_size(nil), do: ""
  defp format_size(n) when is_integer(n) and n < 1024, do: "#{n} B"
  defp format_size(n) when is_integer(n) and n < 1_048_576, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_size(n) when is_integer(n), do: "#{Float.round(n / 1_048_576, 1)} MB"
  defp format_size(_), do: ""

  defp attachment_icon(content_type) when is_binary(content_type) do
    cond do
      String.starts_with?(content_type, "image/") -> "hero-photo"
      content_type == "application/pdf" -> "hero-document-text"
      String.starts_with?(content_type, "text/") -> "hero-document-text"
      String.contains?(content_type, "zip") -> "hero-archive-box"
      true -> "hero-paper-clip"
    end
  end

  defp attachment_icon(_), do: "hero-paper-clip"

  defp avatar_initial(address) when is_binary(address) do
    address |> String.first() |> to_string() |> String.upcase()
  end

  defp avatar_initial(_), do: "?"

  # Deterministic hue so each correspondent keeps a stable avatar color.
  defp avatar_style(seed) do
    hue = :erlang.phash2(seed, 360)
    "background-color: oklch(0.72 0.13 #{hue}); color: oklch(0.24 0.09 #{hue});"
  end

  # -- Function components -----------------------------------------------------

  # Renders a single email's body: sanitized HTML when present, else plain text.
  attr :email, :map, required: true

  defp email_body(assigns) do
    {kind, body} = render_body(assigns.email)
    assigns = assign(assigns, kind: kind, body: body)

    ~H"""
    <div
      :if={@kind == :html}
      class={[
        "mt-2 max-w-full overflow-x-auto text-sm leading-relaxed",
        "[&_a]:text-primary [&_a]:underline",
        "[&_img]:my-2 [&_img]:max-w-full [&_img]:rounded",
        "[&_table]:block [&_table]:max-w-full [&_table]:overflow-x-auto",
        "[&_blockquote]:my-2 [&_blockquote]:border-l-2 [&_blockquote]:border-base-300 [&_blockquote]:pl-3 [&_blockquote]:opacity-80",
        "[&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5"
      ]}
    >
      {raw(@body)}
    </div>
    <div :if={@kind == :text} class="mt-2 whitespace-pre-wrap break-words text-sm leading-relaxed">
      {@body}
    </div>
    """
  end

  # A downloadable chip for one attachment (opens the presigned S3 URL).
  attr :attachment, :map, required: true

  defp attachment_chip(assigns) do
    ~H"""
    <a
      href={~p"/app/mail/attachments/#{@attachment.id}"}
      target="_blank"
      rel="noopener"
      data-test="attachment"
      class="group flex items-center gap-2 rounded-box border border-base-300 bg-base-100 px-3 py-1.5 text-sm transition-colors hover:border-primary hover:bg-primary/5"
    >
      <.icon name={attachment_icon(@attachment.content_type)} class="size-4 shrink-0 opacity-70" />
      <span class="max-w-[12rem] truncate font-medium">{@attachment.filename || "attachment"}</span>
      <span :if={format_size(@attachment.size) != ""} class="shrink-0 text-xs opacity-60">
        {format_size(@attachment.size)}
      </span>
      <.icon name="hero-arrow-down-tray" class="size-4 shrink-0 opacity-0 transition-opacity group-hover:opacity-70" />
    </a>
    """
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_notifications={@pending_notifications}>
      <div class="w-full">
        <header class="flex items-center justify-between gap-3 pb-4">
          <div class="flex items-center gap-2">
            <.icon name="hero-envelope" class="size-6 text-primary" />
            <h1 class="text-2xl font-semibold">Mail</h1>
          </div>
          <.link :if={@can_administer?} navigate={~p"/app/mailboxes"} class="btn btn-ghost btn-sm">
            <.icon name="hero-cog-6-tooth" class="size-4" /> Manage mailboxes
          </.link>
        </header>

        <div :if={not @domain_verified?} data-test="verify-notice" class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>
            Mail can't be sent or received until this project's sending domain is verified.
            {if @can_administer?, do: "Verify it under Manage mailboxes.", else: "Ask an account owner to verify the domain."}
          </span>
        </div>

        <div
          :if={@domain_verified?}
          class="grid grid-cols-1 overflow-hidden rounded-box border border-base-300 bg-base-100 shadow-sm md:grid-cols-[16rem_1fr]"
          style="min-height: calc(100dvh - 11rem)"
        >
          <%!-- Left rail: mailboxes (folders) --%>
          <aside class="flex flex-col border-b border-base-300 bg-base-200/40 p-3 md:border-b-0 md:border-r" data-test="mailboxes">
            <button
              :if={@mailbox}
              type="button"
              data-test="compose-button"
              phx-click="open_modal"
              phx-value-modal="compose"
              class="btn btn-primary mb-4 w-full gap-2 shadow-sm"
            >
              <.icon name="hero-pencil-square" class="size-4" /> Compose
            </button>

            <p class="px-2 py-1 text-xs font-semibold uppercase tracking-wide opacity-50">Mailboxes</p>
            <p :if={@mailboxes == []} data-test="mailboxes-empty" class="px-2 py-2 text-sm opacity-60">
              No mailboxes yet
            </p>
            <ul class="mt-1 flex w-full flex-col gap-1">
              <li :for={mailbox <- @mailboxes}>
                <button
                  type="button"
                  data-test="mailbox"
                  phx-click="open_mailbox"
                  phx-value-id={mailbox.id}
                  class={[
                    "flex w-full items-center gap-2.5 rounded-lg px-2.5 py-2 text-left transition-colors",
                    if(@mailbox && @mailbox.id == mailbox.id,
                      do: "bg-primary/10 font-medium text-primary",
                      else: "hover:bg-base-300/50"
                    )
                  ]}
                >
                  <.icon name="hero-inbox" class="size-4 shrink-0 opacity-70" />
                  <span class="flex min-w-0 flex-col items-start">
                    <span class="w-full truncate text-sm">{mailbox.address}</span>
                    <span class="truncate text-xs opacity-60">{assigned_label(mailbox)}</span>
                  </span>
                </button>
              </li>
            </ul>
          </aside>

          <%!-- Main: conversation list, or an opened conversation --%>
          <main class="flex min-w-0 flex-col bg-base-100">
            <div :if={is_nil(@mailbox)} class="flex flex-1 flex-col items-center justify-center gap-2 p-10 text-center opacity-60">
              <.icon name="hero-inbox-arrow-down" class="size-10 opacity-40" />
              <p class="text-sm">Select a mailbox to read and send mail.</p>
            </div>

            <%!-- List view --%>
            <div :if={@mailbox && is_nil(@current_thread)} data-test="thread-list" class="flex min-h-0 flex-col">
              <div class="flex items-center gap-2 border-b border-base-300 px-4 py-3">
                <span class="truncate font-semibold break-all">{@mailbox.address}</span>
                <span class="badge badge-ghost badge-sm">{length(@threads)}</span>
                <button
                  :if={@can_administer?}
                  type="button"
                  data-test="sync-button"
                  phx-click="sync"
                  class="btn btn-ghost btn-xs ml-auto gap-1"
                  title="Pull inbound mail the webhook may have missed"
                >
                  <.icon name="hero-arrow-path" class="size-3.5" /> Sync
                </button>
              </div>

              <div :if={@threads == []} data-test="threads-empty" class="flex flex-1 flex-col items-center justify-center gap-2 p-10 text-center opacity-60">
                <.icon name="hero-chat-bubble-left-right" class="size-10 opacity-40" />
                <p class="text-sm">No conversations yet — press Compose to start one.</p>
              </div>

              <ul class="divide-y divide-base-200 overflow-y-auto">
                <li
                  :for={thread <- @threads}
                  data-test="thread"
                  phx-click="open_thread"
                  phx-value-key={thread.key}
                  class="flex cursor-pointer items-center gap-3 px-4 py-3 transition-colors hover:bg-base-200/60"
                >
                  <div
                    class="flex size-9 shrink-0 items-center justify-center rounded-full text-sm font-semibold"
                    style={avatar_style(thread.correspondent)}
                  >
                    {avatar_initial(thread.correspondent)}
                  </div>
                  <div class="flex min-w-0 flex-1 flex-col">
                    <div class="flex items-baseline justify-between gap-2">
                      <span class="truncate font-medium">{thread.correspondent}</span>
                      <span class="shrink-0 text-xs opacity-60">{short_at(thread.last_at)}</span>
                    </div>
                    <div class="flex min-w-0 items-center gap-1.5">
                      <.icon
                        :if={thread_has_attachments?(thread)}
                        name="hero-paper-clip"
                        class="size-3.5 shrink-0 opacity-50"
                      />
                      <span class="min-w-0 truncate text-sm">
                        <span class="font-medium">{thread.subject}</span>
                        <span class="opacity-60">— {snippet(thread)}</span>
                      </span>
                    </div>
                  </div>
                </li>
              </ul>
            </div>

            <%!-- Conversation view --%>
            <div :if={@current_thread} data-test="conversation" class="flex min-h-0 flex-1 flex-col">
              <div class="flex items-center gap-2 border-b border-base-300 px-3 py-3">
                <button type="button" data-test="back-to-list" phx-click="close_thread" class="btn btn-ghost btn-sm btn-square">
                  <.icon name="hero-arrow-left" class="size-4" />
                </button>
                <div class="min-w-0">
                  <h2 class="truncate text-lg font-semibold leading-tight">{@current_thread.subject}</h2>
                  <p class="truncate text-xs opacity-60">{@current_thread.correspondent}</p>
                </div>
              </div>

              <div class="flex-1 space-y-3 overflow-y-auto bg-base-200/30 p-4">
                <article
                  :for={email <- @current_thread.emails}
                  data-test="email"
                  data-direction={email.direction}
                  class={[
                    "rounded-box border p-4 shadow-sm",
                    if(email.direction == :outbound,
                      do: "border-primary/20 bg-primary/5",
                      else: "border-base-200 bg-base-100"
                    )
                  ]}
                >
                  <div class="flex items-start gap-3">
                    <div
                      class="flex size-9 shrink-0 items-center justify-center rounded-full text-sm font-semibold"
                      style={avatar_style(email.from_address)}
                    >
                      {avatar_initial(email.from_address)}
                    </div>
                    <div class="min-w-0 flex-1">
                      <div class="flex flex-wrap items-baseline justify-between gap-x-3">
                        <span class="font-medium break-all">{email.from_address}</span>
                        <span class="flex items-center gap-1.5 text-xs opacity-60">
                          <span
                            :if={email.direction == :outbound and not is_nil(email.provider_id)}
                            data-test="email-sent"
                            class="badge badge-success badge-xs gap-1"
                          >
                            <.icon name="hero-check" class="size-3" /> Sent
                          </span>
                          {format_at(email.inserted_at)}
                        </span>
                      </div>
                      <div class="text-xs opacity-60 break-all">
                        to {email.to_address} · {sender_label(email.direction)}
                      </div>

                      <.email_body email={email} />

                      <div :if={attachments(email) != []} data-test="attachments" class="mt-3 flex flex-wrap gap-2">
                        <.attachment_chip :for={att <- attachments(email)} attachment={att} />
                      </div>
                    </div>
                  </div>
                </article>
              </div>

              <div class="border-t border-base-300 bg-base-100 p-3">
                <button type="button" data-test="reply-button" phx-click="open_modal" phx-value-modal="reply" class="btn btn-primary btn-sm gap-2">
                  <.icon name="hero-arrow-uturn-left" class="size-4" /> Reply
                </button>
              </div>
            </div>
          </main>
        </div>
      </div>

      <%!-- Compose modal --%>
      <dialog :if={@mailbox} class={["modal", @modal == :compose && "modal-open"]}>
        <div class="modal-box">
          <h3 class="text-lg font-semibold">New email from {@mailbox.address}</h3>
          <.form for={%{}} phx-submit="compose" data-test="compose-form" class="mt-4 space-y-3">
            <.input name="email[to]" value="" type="email" label="To" placeholder="recipient@example.com" />
            <.input name="email[subject]" value="" type="text" label="Subject" />
            <.input name="email[body]" value="" type="textarea" label="Message" rows="8" />
            <div class="modal-action">
              <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-primary">Send</button>
            </div>
          </.form>
        </div>
        <button type="button" class="modal-backdrop" phx-click="close_modal">close</button>
      </dialog>

      <%!-- Reply modal --%>
      <dialog :if={@current_thread} class={["modal", @modal == :reply && "modal-open"]}>
        <div class="modal-box">
          <h3 class="text-lg font-semibold">Reply to {@current_thread.correspondent}</h3>
          <p class="text-sm opacity-60">from {@mailbox.address}</p>
          <.form for={%{}} phx-submit="reply" data-test="reply-form" class="mt-4 space-y-3">
            <input type="hidden" name="email[to]" value={@current_thread.correspondent} />
            <.input name="email[body]" value="" type="textarea" label="Message" rows="6" />
            <div class="modal-action">
              <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-primary">Send reply</button>
            </div>
          </.form>
        </div>
        <button type="button" class="modal-backdrop" phx-click="close_modal">close</button>
      </dialog>
    </Layouts.app>
    """
  end
end
