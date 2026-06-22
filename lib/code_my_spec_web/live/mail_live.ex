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
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    mailbox = Mail.get_mailbox(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(:mailbox, mailbox)
     |> assign(:page_title, (mailbox && mailbox.address) || "Mail")
     |> assign(:selected, nil)
     |> assign(:current_thread, nil)
     |> load_threads()}
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

  def handle_event("open_thread", %{"key" => key}, socket) do
    {:noreply,
     socket
     |> assign(:selected, key)
     |> assign(:current_thread, thread_by_key(socket.assigns.threads, key))}
  end

  def handle_event("close_thread", _params, socket) do
    {:noreply, socket |> assign(:selected, nil) |> assign(:current_thread, nil)}
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, assign(socket, :modal, String.to_existing_atom(modal))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("compose", %{"email" => %{"to" => to, "subject" => subject, "body" => body}}, socket) do
    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{to: to, subject: subject, body: body})

    {:noreply, socket |> assign(:modal, nil) |> load_threads(select: :latest)}
  end

  def handle_event("reply", %{"email" => %{"to" => to, "body" => body}}, socket) do
    subject = reply_subject(socket.assigns.current_thread)

    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{to: to, subject: subject, body: body})

    {:noreply, socket |> assign(:modal, nil) |> load_threads(select: :latest)}
  end

  defp load_threads(socket, opts \\ [])

  defp load_threads(%{assigns: %{mailbox: nil}} = socket, _opts) do
    socket |> assign(:threads, []) |> assign(:selected, nil) |> assign(:current_thread, nil)
  end

  defp load_threads(%{assigns: %{mailbox: mailbox}} = socket, opts) do
    threads = Mail.list_threads(mailbox)

    # Default: stay in the list (no thread auto-opened). compose/reply open the
    # just-touched thread; an explicit selection is kept if it still exists.
    selected =
      cond do
        opts[:select] == :latest -> threads |> List.first() |> then(&(&1 && &1.key))
        socket.assigns.selected && Enum.any?(threads, &(&1.key == socket.assigns.selected)) -> socket.assigns.selected
        true -> nil
      end

    socket
    |> assign(:threads, threads)
    |> assign(:selected, selected)
    |> assign(:current_thread, selected && thread_by_key(threads, selected))
  end

  defp reply_subject(%{subject: subject}) when is_binary(subject), do: prefix_re(subject)
  defp reply_subject(_), do: "Re:"

  defp prefix_re("Re:" <> _ = subject), do: subject
  defp prefix_re(subject), do: "Re: #{subject}"

  defp thread_by_key(threads, key), do: Enum.find(threads, &(&1.key == key))

  defp assigned_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp assigned_label(_mailbox), do: "Shared"

  defp sender_label(:outbound), do: "You"
  defp sender_label(_direction), do: "Them"

  defp format_at(nil), do: ""
  defp format_at(%DateTime{} = at), do: Calendar.strftime(at, "%b %-d, %-I:%M %p")

  # First line of the thread's latest message, for the list-row preview.
  defp snippet(%{emails: emails}) do
    case List.last(emails) do
      %{body_text: body} when is_binary(body) ->
        body |> String.split("\n", parts: 2) |> List.first() |> String.slice(0, 140)

      _ ->
        ""
    end
  end

  defp avatar_initial(address) when is_binary(address) do
    address |> String.first() |> to_string() |> String.upcase()
  end

  defp avatar_initial(_), do: "?"

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="w-full">
        <header class="flex items-center justify-between gap-3 pb-4">
          <h1 class="text-2xl font-semibold">Mail</h1>
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
          class="grid grid-cols-1 overflow-hidden rounded-box border border-base-300 md:grid-cols-[15rem_1fr]"
          style="min-height: calc(100dvh - 11rem)"
        >
          <%!-- Left rail: mailboxes (folders) --%>
          <aside class="border-b border-base-300 bg-base-200/40 p-2 md:border-b-0 md:border-r" data-test="mailboxes">
            <button
              :if={@mailbox}
              type="button"
              data-test="compose-button"
              phx-click="open_modal"
              phx-value-modal="compose"
              class="btn btn-primary mb-3 w-full justify-start gap-2"
            >
              <.icon name="hero-pencil-square" class="size-4" /> Compose
            </button>

            <p class="px-2 py-1 text-xs font-semibold uppercase opacity-60">Mailboxes</p>
            <p :if={@mailboxes == []} data-test="mailboxes-empty" class="px-2 py-2 text-sm opacity-60">
              No mailboxes yet
            </p>
            <ul class="menu menu-sm w-full gap-0.5">
              <li :for={mailbox <- @mailboxes}>
                <button
                  type="button"
                  data-test="mailbox"
                  phx-click="open_mailbox"
                  phx-value-id={mailbox.id}
                  class={["gap-2", @mailbox && @mailbox.id == mailbox.id && "menu-active font-medium"]}
                >
                  <.icon name="hero-inbox" class="size-4 shrink-0" />
                  <span class="flex min-w-0 flex-col items-start">
                    <span class="w-full truncate">{mailbox.address}</span>
                    <span class="text-xs opacity-60">{assigned_label(mailbox)}</span>
                  </span>
                </button>
              </li>
            </ul>
          </aside>

          <%!-- Main: conversation list, or an opened conversation --%>
          <main class="min-w-0 bg-base-100">
            <div :if={is_nil(@mailbox)} class="p-6 text-sm opacity-60">
              Select a mailbox to read and send mail.
            </div>

            <%!-- List view --%>
            <div :if={@mailbox && is_nil(@current_thread)} data-test="thread-list">
              <div class="flex items-center gap-2 border-b border-base-300 px-3 py-2">
                <span class="font-medium break-all">{@mailbox.address}</span>
                <span class="badge badge-ghost badge-sm">{length(@threads)}</span>
              </div>

              <p :if={@threads == []} data-test="threads-empty" class="p-6 text-sm opacity-60">
                No conversations yet — press Compose to start one.
              </p>

              <ul class="divide-y divide-base-200">
                <li
                  :for={thread <- @threads}
                  data-test="thread"
                  phx-click="open_thread"
                  phx-value-key={thread.key}
                  class="flex cursor-pointer items-center gap-3 px-3 py-2 hover:bg-base-200/60"
                >
                  <div class="flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/15 text-sm font-semibold text-primary">
                    {avatar_initial(thread.correspondent)}
                  </div>
                  <span class="w-44 shrink-0 truncate font-medium">{thread.correspondent}</span>
                  <span class="min-w-0 flex-1 truncate">
                    <span class="font-medium">{thread.subject}</span>
                    <span class="opacity-60">— {snippet(thread)}</span>
                  </span>
                  <span class="shrink-0 text-xs opacity-60">{format_at(thread.last_at)}</span>
                </li>
              </ul>
            </div>

            <%!-- Conversation view --%>
            <div :if={@current_thread} data-test="conversation" class="flex h-full flex-col">
              <div class="flex items-center gap-2 border-b border-base-300 px-3 py-2">
                <button type="button" data-test="back-to-list" phx-click="close_thread" class="btn btn-ghost btn-sm btn-square">
                  <.icon name="hero-arrow-left" class="size-4" />
                </button>
                <h2 class="truncate text-lg font-semibold">{@current_thread.subject}</h2>
              </div>

              <div class="flex-1 space-y-3 overflow-y-auto p-4">
                <article
                  :for={email <- @current_thread.emails}
                  data-test="email"
                  data-direction={email.direction}
                  class="rounded-box border border-base-200 p-3"
                >
                  <div class="flex items-start gap-3">
                    <div class="flex size-8 shrink-0 items-center justify-center rounded-full bg-base-300 text-sm font-semibold">
                      {avatar_initial(email.from_address)}
                    </div>
                    <div class="min-w-0 flex-1">
                      <div class="flex flex-wrap items-baseline justify-between gap-x-3">
                        <span class="font-medium break-all">{email.from_address}</span>
                        <span class="flex items-center gap-1 text-xs opacity-60">
                          <span
                            :if={email.direction == :outbound and not is_nil(email.provider_id)}
                            data-test="email-sent"
                            class="badge badge-success badge-xs"
                          >
                            Sent
                          </span>
                          {format_at(email.inserted_at)}
                        </span>
                      </div>
                      <div class="text-xs opacity-60 break-all">
                        to {email.to_address} · {sender_label(email.direction)}
                      </div>
                      <div class="mt-2 whitespace-pre-wrap break-words text-sm">{email.body_text}</div>
                    </div>
                  </div>
                </article>
              </div>

              <div class="border-t border-base-300 p-3">
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
