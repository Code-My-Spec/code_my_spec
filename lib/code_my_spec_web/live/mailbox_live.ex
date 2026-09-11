defmodule CodeMySpecWeb.MailboxLive do
  @moduledoc """
  Mailbox administration for a project — **owners and admins only**. Here an
  operator creates and administers the mailboxes (assigned to a user, or
  shared, or the catch-all). Reading and sending mail lives on the separate
  Mail inbox (`CodeMySpecWeb.MailLive`); this surface is purely administrative.

  The sending domain those mailboxes ride on is set up in project settings
  (`CodeMySpecWeb.ProjectLive.Form`); mailboxes stay gated here until it's
  verified.

  Members are redirected to the inbox — they use mailboxes, they don't manage
  them.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.{Accounts, Mail}
  alias CodeMySpec.Projects.Project

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if Mail.can_administer?(scope) do
      project = scope.active_project

      {:ok,
       socket
       |> assign(:page_title, "Mailboxes")
       |> assign(:project, project)
       |> assign(:domain_verified?, Project.domain_verified?(project))
       |> assign(:domain, project && project.domain)
       |> assign(:assignable_users, assignable_users(scope))
       |> assign(:modal, nil)
       |> assign(:mailboxes, Mail.list_mailboxes(scope))}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only account owners and admins can administer mailboxes.")
       |> redirect(to: ~p"/app/projects/#{socket.assigns.project.id}/mail")}
    end
  end

  @impl true
  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, assign(socket, :modal, String.to_existing_atom(modal))}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :modal, nil)}
  end

  def handle_event("create_mailbox", %{"mailbox" => params}, socket) do
    scope = socket.assigns.current_scope

    case Mail.create_mailbox(scope, params) do
      {:ok, _mailbox} ->
        {:noreply,
         socket
         |> assign(:mailboxes, Mail.list_mailboxes(scope))
         |> assign(:modal, nil)
         |> put_flash(:info, "Mailbox created.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Could not create mailbox — check the address.")}
    end
  end

  def handle_event("sync_inbound", _params, socket) do
    case Mail.sync_inbound(socket.assigns.project) do
      {:ok, %{synced: synced, new: new, backfilled: backfilled}} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Synced #{synced} message(s) — #{new} new, #{backfilled} backfilled."
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, domain_error_message(reason))}
    end
  end

  defp domain_error_message(:resend_not_configured),
    do: "Email provider isn't configured yet (missing RESEND_API_KEY)."

  defp domain_error_message(:no_domain), do: "No domain has been registered yet."

  defp domain_error_message({:resend_error, status, body}) do
    case resend_message(body) do
      nil -> "The email provider returned an error (HTTP #{status}). Check the domain and try again."
      message -> "The email provider rejected the request (HTTP #{status}): #{message}"
    end
  end

  defp domain_error_message(_reason),
    do: "Could not reach the email provider. Please try again."

  defp resend_message(%{"message" => message}) when is_binary(message), do: message
  defp resend_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp resend_message(_body), do: nil

  defp assignable_users(scope) do
    scope
    |> Accounts.list_account_members(scope.active_account_id)
    |> Enum.map(& &1.user)
    |> Enum.reject(&is_nil/1)
  end

  defp user_options(users), do: [{"Shared (no user)", ""}] ++ Enum.map(users, &{&1.email, &1.id})

  defp assigned_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp assigned_label(_mailbox), do: "Shared"

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div class="mx-auto w-full max-w-4xl">
        <header class="flex items-center justify-between gap-3 pb-4">
          <h1 class="text-2xl font-semibold">Mailboxes</h1>
          <div class="flex items-center gap-2">
            <button
              :if={@domain_verified?}
              type="button"
              phx-click="open_modal"
              phx-value-modal="mailbox"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-plus" class="size-4" /> New mailbox
            </button>
            <button
              :if={@domain_verified?}
              type="button"
              data-test="sync-inbound"
              phx-click="sync_inbound"
              class="btn btn-ghost btn-sm"
            >
              <.icon name="hero-arrow-path" class="size-4" /> Sync mail
            </button>
            <.link navigate={~p"/app/projects/#{@project.id}/mail"} class="btn btn-ghost btn-sm">
              <.icon name="hero-envelope" class="size-4" /> Go to Mail
            </.link>
          </div>
        </header>

        <section :if={not @domain_verified?} data-test="domain-gate" class="space-y-4">
          <div data-test="verify-notice" class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>Verify your sending domain before mail can be sent or received.</span>
          </div>

          <div class="rounded-box bg-base-200 p-6 text-center">
            <p :if={is_nil(@domain)} class="mb-3 opacity-70">No sending domain yet.</p>
            <p :if={not is_nil(@domain)} class="mb-3 opacity-70">
              <span class="font-mono">{@domain}</span> isn't verified yet.
            </p>
            <.link
              :if={@project}
              navigate={~p"/app/projects/#{@project}/edit"}
              data-test="domain-settings-link"
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-globe-alt" class="size-4" /> Set up the domain in project settings
            </.link>
          </div>
        </section>

        <section :if={@domain_verified?}>
          <div class="overflow-x-auto rounded-box border border-base-300">
            <table class="table">
              <thead>
                <tr>
                  <th>Address</th>
                  <th>Assigned to</th>
                </tr>
              </thead>
              <tbody>
                <tr :if={@mailboxes == []} data-test="mailboxes-empty">
                  <td colspan="2" class="text-center opacity-60">No mailboxes yet — create one above.</td>
                </tr>
                <tr :for={mailbox <- @mailboxes} data-test="mailbox">
                  <td class="break-all font-medium">
                    {mailbox.address}
                    <span :if={mailbox.catch_all} class="badge badge-ghost badge-sm">catch-all</span>
                  </td>
                  <td class="break-all">{assigned_label(mailbox)}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>

      <%!-- New-mailbox modal --%>
      <dialog class={["modal", @modal == :mailbox && "modal-open"]}>
        <div class="modal-box">
          <h3 class="text-lg font-semibold">New mailbox</h3>
          <.form for={%{}} phx-submit="create_mailbox" data-test="new-mailbox-form" class="mt-4 space-y-3">
            <.input name="mailbox[address]" value="" type="text" label="Address" placeholder={"support@#{@domain}"} />
            <.input
              name="mailbox[user_id]"
              value=""
              type="select"
              label="Assigned to"
              options={user_options(@assignable_users)}
            />
            <.input name="mailbox[catch_all]" value="false" type="checkbox" label="Catch-all mailbox" />
            <div class="modal-action">
              <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-primary">Create mailbox</button>
            </div>
          </.form>
        </div>
        <button type="button" class="modal-backdrop" phx-click="close_modal">close</button>
      </dialog>

    </Layouts.app>
    """
  end
end
