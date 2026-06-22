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
       |> assign(:modal, nil)
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
         |> assign(:modal, nil)
         |> put_flash(:info, "Domain added — publish the DNS records below, then verify.")}

      {:error, reason} ->
        {:noreply, socket |> assign(:domain_error, domain_error_message(reason)) |> assign(:modal, nil)}
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

  defp user_options(users), do: [{"Shared (no user)", ""}] ++ Enum.map(users, &{&1.email, &1.id})

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
            <.link navigate={~p"/app/mail"} class="btn btn-ghost btn-sm">
              <.icon name="hero-envelope" class="size-4" /> Go to Mail
            </.link>
          </div>
        </header>

        <section :if={not @domain_verified?} data-test="domain-setup" class="space-y-4">
          <div data-test="verify-notice" class="alert alert-warning">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>Verify your sending domain before mail can be sent or received.</span>
          </div>

          <p :if={@domain_error} data-test="domain-error" class="text-error text-sm">{@domain_error}</p>

          <div :if={is_nil(@domain)} class="rounded-box bg-base-200 p-6 text-center">
            <p class="mb-3 opacity-70">No sending domain yet.</p>
            <button type="button" phx-click="open_modal" phx-value-modal="domain" class="btn btn-primary btn-sm">
              <.icon name="hero-globe-alt" class="size-4" /> Add a domain
            </button>
          </div>

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
              (use a subdomain so it doesn't affect existing mail).
            </p>

            <button type="button" phx-click="verify_domain" data-test="verify-domain" class="btn btn-primary btn-sm">
              Verify domain
            </button>
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

      <%!-- Add-domain modal --%>
      <dialog class={["modal", @modal == :domain && "modal-open"]}>
        <div class="modal-box">
          <h3 class="text-lg font-semibold">Add a sending domain</h3>
          <p class="mt-1 text-sm opacity-70">
            Use a subdomain (e.g. <span class="font-mono">inbound.yourdomain.com</span>) so it doesn't
            collide with existing mail on your root domain.
          </p>
          <.form for={%{}} phx-submit="setup_domain" data-test="add-domain-form" class="mt-4 space-y-3">
            <.input name="project[domain]" value="" type="text" label="Sending domain" placeholder="inbound.yourdomain.com" />
            <div class="modal-action">
              <button type="button" phx-click="close_modal" class="btn btn-ghost">Cancel</button>
              <button type="submit" class="btn btn-primary">Add domain</button>
            </div>
          </.form>
        </div>
        <button type="button" class="modal-backdrop" phx-click="close_modal">close</button>
      </dialog>
    </Layouts.app>
    """
  end
end
