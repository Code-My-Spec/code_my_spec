defmodule CodeMySpecWeb.MailLive do
  @moduledoc """
  The operator's mail inbox — a three-pane email client over the project's
  mailboxes. The left sidebar lists the mailboxes the current member may see
  (role-scoped: owners/admins see all, members see shared + their own); the
  middle pane lists a mailbox's per-correspondent threads; the reading pane
  renders the selected thread as email (headers + subject + full body, not a
  chat transcript). Composing and replying happen in modal dialogs.

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

  def handle_event("select_thread", %{"correspondent" => correspondent}, socket) do
    current = correspondent != "" && selected_thread(socket.assigns.threads, correspondent)

    {:noreply,
     socket
     |> assign(:selected, correspondent)
     |> assign(:current_thread, current || nil)}
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

    {:noreply, socket |> assign(:modal, nil) |> load_threads(select: to)}
  end

  def handle_event("reply", %{"email" => %{"to" => to, "body" => body}}, socket) do
    subject = reply_subject(socket.assigns.threads, to)

    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{to: to, subject: subject, body: body})

    {:noreply, socket |> assign(:modal, nil) |> load_threads(select: to)}
  end

  defp load_threads(socket, opts \\ [])

  defp load_threads(%{assigns: %{mailbox: nil}} = socket, _opts) do
    socket |> assign(:threads, []) |> assign(:selected, nil) |> assign(:current_thread, nil)
  end

  defp load_threads(%{assigns: %{mailbox: mailbox}} = socket, opts) do
    threads = Mail.list_threads(mailbox)

    selected =
      cond do
        opts[:select] ->
          opts[:select]

        socket.assigns.selected && Enum.any?(threads, &(&1.correspondent == socket.assigns.selected)) ->
          socket.assigns.selected

        true ->
          case threads do
            [first | _] -> first.correspondent
            [] -> nil
          end
      end

    current = selected && selected_thread(threads, selected)

    socket
    |> assign(:threads, threads)
    |> assign(:selected, selected)
    |> assign(:current_thread, current)
  end

  defp reply_subject(threads, correspondent) do
    case Enum.find(threads, &(&1.correspondent == correspondent)) do
      %{subject: subject} when is_binary(subject) -> prefix_re(subject)
      _ -> "Re:"
    end
  end

  defp prefix_re("Re:" <> _ = subject), do: subject
  defp prefix_re(subject), do: "Re: #{subject}"

  defp selected_thread(threads, correspondent),
    do: Enum.find(threads, &(&1.correspondent == correspondent))

  defp assigned_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp assigned_label(_mailbox), do: "Shared"

  defp sender_label(:outbound), do: "You"
  defp sender_label(_direction), do: "Them"

  defp format_at(nil), do: ""
  defp format_at(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-6xl">
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
          class="grid grid-cols-1 gap-4 md:grid-cols-[14rem_18rem_1fr]"
          style="min-height: calc(100dvh - 12rem)"
        >
          <%!-- Pane 1: mailboxes --%>
          <aside class="rounded-box border border-base-300 p-2" data-test="mailboxes">
            <p class="px-2 py-1 text-xs font-semibold uppercase opacity-60">Mailboxes</p>
            <p :if={@mailboxes == []} data-test="mailboxes-empty" class="px-2 py-2 text-sm opacity-60">
              No mailboxes yet
            </p>
            <ul class="menu menu-sm w-full">
              <li :for={mailbox <- @mailboxes}>
                <button
                  type="button"
                  data-test="mailbox"
                  phx-click="open_mailbox"
                  phx-value-id={mailbox.id}
                  class={[@mailbox && @mailbox.id == mailbox.id && "menu-active"]}
                >
                  <span class="flex flex-col items-start">
                    <span class="break-all font-medium">{mailbox.address}</span>
                    <span class="text-xs opacity-60">{assigned_label(mailbox)}</span>
                  </span>
                </button>
              </li>
            </ul>
          </aside>

          <%!-- Pane 2: threads --%>
          <section class="rounded-box border border-base-300" data-test="threads">
            <div :if={is_nil(@mailbox)} class="p-4 text-sm opacity-60">Select a mailbox.</div>

            <div :if={@mailbox}>
              <div class="flex items-center justify-between border-b border-base-300 p-2">
                <span class="px-1 text-xs font-semibold uppercase opacity-60">Conversations</span>
                <button type="button" data-test="compose-button" phx-click="open_modal" phx-value-modal="compose" class="btn btn-primary btn-xs">
                  <.icon name="hero-pencil-square" class="size-3" /> New
                </button>
              </div>

              <p :if={@threads == []} data-test="threads-empty" class="p-4 text-sm opacity-60">
                No conversations yet — start one with “New”.
              </p>

              <ul class="menu menu-sm w-full">
                <li :for={thread <- @threads}>
                  <button
                    type="button"
                    data-test="thread"
                    phx-click="select_thread"
                    phx-value-correspondent={thread.correspondent}
                    class={[@selected == thread.correspondent && "menu-active"]}
                  >
                    <span class="flex w-full flex-col items-start">
                      <span class="break-all font-medium">{thread.correspondent}</span>
                      <span class="w-full truncate text-xs opacity-60">{thread.subject}</span>
                      <span class="text-[0.65rem] opacity-50">{format_at(thread.last_at)}</span>
                    </span>
                  </button>
                </li>
              </ul>
            </div>
          </section>

          <%!-- Pane 3: reading --%>
          <section class="rounded-box border border-base-300 p-4" data-test="reading-pane">
            <div :if={is_nil(@mailbox)} class="text-sm opacity-60">
              Choose a mailbox to read and send mail.
            </div>

            <div :if={@mailbox && is_nil(@current_thread)} class="text-sm opacity-60">
              Select a conversation, or press “New” to compose.
            </div>

            <div :if={@current_thread} class="space-y-4">
              <header class="flex items-start justify-between gap-3 border-b border-base-300 pb-2">
                <div class="min-w-0">
                  <h2 class="text-lg font-semibold break-all">{@current_thread.subject}</h2>
                  <p class="text-sm opacity-60">with {@current_thread.correspondent}</p>
                </div>
                <button type="button" data-test="reply-button" phx-click="open_modal" phx-value-modal="reply" class="btn btn-primary btn-sm shrink-0">
                  <.icon name="hero-arrow-uturn-left" class="size-4" /> Reply
                </button>
              </header>

              <article
                :for={email <- @current_thread.emails}
                data-test="email"
                data-direction={email.direction}
                class="rounded-box border border-base-200 bg-base-100 p-3"
              >
                <div class="flex flex-wrap items-baseline justify-between gap-x-3 text-sm">
                  <span class="font-medium break-all">{email.from_address}</span>
                  <span class="text-xs opacity-50">{format_at(email.inserted_at)}</span>
                </div>
                <div class="text-xs opacity-60 break-all">
                  to {email.to_address} · <span class="badge badge-ghost badge-xs">{sender_label(email.direction)}</span>
                </div>
                <div :if={email.subject} class="mt-1 text-sm font-medium">{email.subject}</div>
                <div class="mt-2 whitespace-pre-wrap break-words text-sm">{email.body_text}</div>
              </article>
            </div>
          </section>
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
