defmodule CodeMySpecWeb.MailboxLive do
  @moduledoc """
  Mailbox administration for a project — **owners and admins only**. Here an
  operator sets up the project's sending domain (register → publish DNS →
  verify) and creates/administers the mailboxes (assigned to a user, or shared,
  or the catch-all). Reading and sending mail lives on the separate Mail inbox
  (`CodeMySpecWeb.MailLive`); this surface is purely administrative.

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
       |> assign(:dns_records, [])
       |> assign(:domain_status, nil)
       |> assign(:domain_error, nil)
       |> assign(:mailboxes, Mail.list_mailboxes(scope))
       |> maybe_load_domain_state()}
    else
      {:ok,
       socket
       |> put_flash(:error, "Only account owners and admins can administer mailboxes.")
       |> redirect(to: ~p"/app/mail")}
    end
  end

  @impl true
  def handle_event("create_mailbox", %{"mailbox" => params}, socket) do
    scope = socket.assigns.current_scope

    socket =
      case Mail.create_mailbox(scope, params) do
        {:ok, _mailbox} ->
          socket
          |> assign(:mailboxes, Mail.list_mailboxes(scope))
          |> put_flash(:info, "Mailbox created.")

        {:error, _changeset} ->
          put_flash(socket, :error, "Could not create mailbox — check the address.")
      end

    {:noreply, socket}
  end

  def handle_event("setup_domain", %{"project" => %{"domain" => domain}}, socket) do
    scope = socket.assigns.current_scope

    case Mail.setup_domain(scope, socket.assigns.project, domain) do
      {:ok, project, records} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:domain, project.domain)
         |> assign(:domain_verified?, Project.domain_verified?(project))
         |> assign(:dns_records, records)
         |> assign(:domain_status, if(Project.domain_verified?(project), do: "verified", else: "pending"))
         |> assign(:domain_error, nil)
         |> put_flash(:info, "Domain added — publish the DNS records below, then verify.")}

      {:error, reason} ->
        {:noreply, assign(socket, :domain_error, domain_error_message(reason))}
    end
  end

  def handle_event("verify_domain", _params, socket) do
    scope = socket.assigns.current_scope

    case Mail.verify_domain(scope, socket.assigns.project) do
      {:ok, project, :verified} ->
        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:domain_verified?, true)
         |> assign(:domain_error, nil)
         |> put_flash(:info, "Domain verified — mail is now enabled.")}

      {:ok, _project, status} ->
        {:noreply,
         socket
         |> assign(:domain_status, status)
         |> put_flash(:error, "Domain not verified yet (status: #{status}). Add the DNS records and try again.")}

      {:error, reason} ->
        {:noreply, assign(socket, :domain_error, domain_error_message(reason))}
    end
  end

  defp maybe_load_domain_state(socket) do
    project = socket.assigns.project

    cond do
      socket.assigns.domain_verified? -> socket
      is_nil(project) or is_nil(project.resend_domain_id) -> socket
      not connected?(socket) -> socket
      true -> load_domain_state(socket, project)
    end
  end

  defp load_domain_state(socket, project) do
    case Mail.domain_dns_records(project) do
      {:ok, records, status} ->
        socket |> assign(:dns_records, records) |> assign(:domain_status, status)

      {:error, reason} ->
        assign(socket, :domain_error, domain_error_message(reason))
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

  defp assigned_label(%{user: %{email: email}}) when is_binary(email), do: email
  defp assigned_label(_mailbox), do: "Shared"

  # -- Render -----------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto w-full max-w-4xl">
        <header class="flex items-center justify-between gap-3 pb-4">
          <h1 class="text-2xl font-semibold">Mailboxes</h1>
          <.link navigate={~p"/app/mail"} class="btn btn-ghost btn-sm">
            <.icon name="hero-envelope" class="size-4" /> Go to Mail
          </.link>
        </header>

        <section :if={not @domain_verified?} data-test="domain-setup" class="space-y-4">
          <div data-test="verify-notice" class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>Verify your sending domain before mail can be sent or received.</span>
          </div>

          <p :if={@domain_error} data-test="domain-error" class="text-error text-sm">{@domain_error}</p>

          <form
            :if={is_nil(@domain)}
            phx-submit="setup_domain"
            data-test="add-domain-form"
            class="flex flex-wrap items-end gap-2 rounded-box bg-base-200 p-4"
          >
            <label class="form-control flex-1">
              <span class="label-text">Sending domain</span>
              <input
                type="text"
                name="project[domain]"
                placeholder="inbound.yourdomain.com"
                class="input input-bordered input-sm"
              />
            </label>
            <button type="submit" class="btn btn-primary btn-sm">Add domain</button>
          </form>

          <div :if={not is_nil(@domain)} data-test="domain-pending" class="space-y-3 rounded-box bg-base-200 p-4">
            <p class="flex items-center gap-2">
              <span class="opacity-70">Domain:</span>
              <span class="font-mono">{@domain}</span>
              <span class="badge badge-ghost badge-sm">{@domain_status || "pending"}</span>
            </p>

            <div :if={@dns_records != []} class="overflow-x-auto">
              <p class="mb-1 text-sm opacity-70">Add these records at your DNS provider:</p>
              <table class="table table-sm" data-test="dns-records">
                <thead>
                  <tr>
                    <th>Type</th>
                    <th>Name</th>
                    <th>Value</th>
                    <th>Priority</th>
                    <th>Status</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={record <- @dns_records}>
                    <td>{record["type"] || record["record"]}</td>
                    <td class="break-all font-mono text-xs">{record["name"]}</td>
                    <td class="break-all font-mono text-xs">{record["value"]}</td>
                    <td>{record["priority"]}</td>
                    <td>{record["status"]}</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p class="text-sm opacity-70">
              To <strong>receive</strong> mail, also enable receiving and add the MX record on the
              <.link href="https://resend.com/domains" target="_blank" rel="noopener" class="link">
                Resend dashboard
              </.link>
              (see the project's email setup notes).
            </p>

            <button type="button" phx-click="verify_domain" data-test="verify-domain" class="btn btn-primary btn-sm">
              Verify domain
            </button>
          </div>
        </section>

        <section :if={@domain_verified?}>
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
    </Layouts.app>
    """
  end
end
