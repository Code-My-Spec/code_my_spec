defmodule CodeMySpecWeb.MailboxLive do
  @moduledoc """
  The operator's mail surface for a project's verified domain. `:index` lists
  the mailboxes the current member may see (role-scoped) and offers a
  new-mailbox form; `:show` opens one mailbox as per-correspondent threads the
  operator can compose into or reply from.

  Mail only flows on a verified domain: until the project's sending domain is
  verified, the index shows a verification notice and no compose surface.

  Styling mirrors the vetted `CodeMySpecWeb.InboxLive` patterns (table index,
  chat-bubble threads), rendered in CodeMySpec's own DaisyUI theme.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.{Accounts, Mail}
  alias CodeMySpec.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:domain_verified?, Project.domain_verified?(scope.active_project))
     |> assign(:domain, scope.active_project && scope.active_project.domain)
     |> assign(:assignable_users, assignable_users(scope))
     |> assign(:mailbox, nil)
     |> assign(:threads, [])
     |> assign(:mailboxes, Mail.list_mailboxes(scope))}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{live_action: :show}} = socket) do
    mailbox = Mail.get_mailbox(socket.assigns.current_scope, id)

    {:noreply,
     socket
     |> assign(:mailbox, mailbox)
     |> assign(:page_title, mailbox && mailbox.address)
     |> load_threads()}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:mailbox, nil)
     |> assign(:page_title, "Mailboxes")
     |> assign(:mailboxes, Mail.list_mailboxes(socket.assigns.current_scope))}
  end

  @impl true
  def handle_event("open_mailbox", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/app/mailboxes/#{id}")}
  end

  def handle_event("create_mailbox", %{"mailbox" => params}, socket) do
    scope = socket.assigns.current_scope

    socket =
      case Mail.create_mailbox(scope, params) do
        {:ok, _mailbox} ->
          assign(socket, :mailboxes, Mail.list_mailboxes(scope))

        {:error, _changeset} ->
          put_flash(socket, :error, "Could not create mailbox")
      end

    {:noreply, socket}
  end

  def handle_event("compose", %{"email" => %{"to" => to, "subject" => subject, "body" => body}}, socket) do
    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{to: to, subject: subject, body: body})

    {:noreply, load_threads(socket)}
  end

  def handle_event("reply", %{"email" => %{"to" => to, "body" => body}}, socket) do
    {:ok, _email} =
      Mail.send_outbound(socket.assigns.mailbox, %{
        to: to,
        subject: "Re:",
        body: body
      })

    {:noreply, load_threads(socket)}
  end

  defp load_threads(%{assigns: %{mailbox: nil}} = socket), do: assign(socket, :threads, [])

  defp load_threads(%{assigns: %{mailbox: mailbox}} = socket) do
    assign(socket, :threads, Mail.list_threads(mailbox))
  end

  defp assignable_users(scope) do
    scope
    |> Accounts.list_account_members(scope.active_account_id)
    |> Enum.map(& &1.user)
    |> Enum.reject(&is_nil/1)
  end

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(%{live_action: :show} = assigns), do: render_show(assigns)
  def render(assigns), do: render_index(assigns)

  defp render_index(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-4xl">
        <header class="flex items-center justify-between gap-3 pb-4">
          <h1 class="text-2xl font-semibold">Mailboxes</h1>
        </header>

        <div :if={not @domain_verified?} data-test="verify-notice" class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>
            Verify your sending domain{if @domain, do: " (#{@domain})"} before mail can be
            sent or received. Verify the domain to enable mailboxes.
          </span>
        </div>

        <div :if={@domain_verified?}>
          <form
            phx-submit="create_mailbox"
            data-test="new-mailbox-form"
            class="mb-6 flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-4"
          >
            <label class="form-control">
              <span class="label-text">Address</span>
              <input
                type="text"
                name="mailbox[address]"
                placeholder={"support@#{@domain}"}
                class="input input-bordered input-sm"
              />
            </label>

            <label class="form-control">
              <span class="label-text">Assigned to</span>
              <select name="mailbox[user_id]" class="select select-bordered select-sm">
                <option value="">Shared</option>
                <option :for={user <- @assignable_users} value={user.id}>{user.email}</option>
              </select>
            </label>

            <label class="form-control">
              <span class="label-text">Catch-all</span>
              <input type="checkbox" name="mailbox[catch_all]" value="true" class="checkbox" />
            </label>

            <button type="submit" class="btn btn-primary btn-sm">Create mailbox</button>
          </form>

          <div class="overflow-x-auto">
            <table class="table">
              <thead>
                <tr>
                  <th>Address</th>
                  <th>Assigned to</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@mailboxes == []} data-test="mailboxes-empty">
                  <td colspan="2" class="text-center opacity-60">No mailboxes yet</td>
                </tr>
                <tr
                  :for={mailbox <- @mailboxes}
                  data-test="mailbox"
                  phx-click="open_mailbox"
                  phx-value-id={mailbox.id}
                  class="cursor-pointer hover"
                >
                  <td class="break-all font-medium">
                    {mailbox.address}
                    <span :if={mailbox.catch_all} class="badge badge-ghost badge-sm">catch-all</span>
                  </td>
                  <td class="break-all">{assigned_label(mailbox)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp render_show(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-3xl">
        <header class="flex items-center gap-2 border-b border-base-300 pb-3">
          <.link navigate={~p"/app/mailboxes"} data-test="back-to-mailboxes" class="btn btn-ghost btn-xs">
            <.icon name="hero-arrow-left" class="size-4" /> Mailboxes
          </.link>
          <h1 class="truncate text-lg font-semibold">{@mailbox && @mailbox.address}</h1>
        </header>

        <div :if={@domain_verified? && @mailbox} class="space-y-6 py-4">
          <section data-test="compose" class="rounded-box bg-base-200 p-4">
            <h2 class="mb-2 font-semibold">New email</h2>
            <form phx-submit="compose" data-test="compose-form" class="flex flex-col gap-2">
              <input
                type="text"
                name="email[to]"
                placeholder="recipient@example.com"
                class="input input-bordered input-sm"
              />
              <input
                type="text"
                name="email[subject]"
                placeholder="Subject"
                class="input input-bordered input-sm"
              />
              <textarea name="email[body]" placeholder="Message" class="textarea textarea-bordered"></textarea>
              <button type="submit" class="btn btn-primary btn-sm self-start">Send from {@mailbox.address}</button>
            </form>
          </section>

          <section
            :for={thread <- @threads}
            data-test="thread"
            data-correspondent={thread.correspondent}
            class="rounded-box border border-base-300 p-4"
          >
            <h3 class="mb-3 font-medium opacity-70">{thread.correspondent}</h3>

            <div class="space-y-2">
              <div
                :for={email <- thread.emails}
                data-test="email"
                data-direction={email.direction}
                class={["chat", chat_side(email.direction)]}
              >
                <div class="chat-header text-xs opacity-60">
                  {email.from_address}
                  <span :if={email.subject} class="font-medium">· {email.subject}</span>
                </div>
                <div class={["chat-bubble whitespace-pre-wrap break-words", chat_bubble(email.direction)]}>
                  {email.body_text}
                </div>
              </div>
            </div>

            <form phx-submit="reply" data-test="reply-form" class="mt-3 flex gap-2">
              <input type="hidden" name="email[to]" value={thread.correspondent} />
              <input
                type="text"
                name="email[body]"
                placeholder={"Reply from #{@mailbox.address}"}
                autocomplete="off"
                class="input input-bordered input-sm flex-1"
              />
              <button type="submit" class="btn btn-primary btn-sm">Reply</button>
            </form>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # -- Helpers ----------------------------------------------------------------

  defp assigned_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp assigned_label(_mailbox), do: "Shared"

  defp chat_side(:outbound), do: "chat-end"
  defp chat_side(_direction), do: "chat-start"

  defp chat_bubble(:outbound), do: "chat-bubble-primary"
  defp chat_bubble(_direction), do: "bg-base-200 text-base-content"
end
