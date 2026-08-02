defmodule CodeMySpecWeb.ProjectLive.Form do
  @moduledoc """
  Create and edit a project.

  The sending domain lives here too (register → publish DNS → verify), but
  it is deliberately **not** a field on the main form: setting `domain`
  registers it with the mail provider and records the provider's domain id,
  so it moves through `Mail.setup_domain/3` on its own submit rather than the
  project save. It only appears when editing (registration needs a persisted
  project) and only for account owners/admins, who are the ones who
  administer mail.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.{Mail, Projects}
  alias CodeMySpec.Projects.Project

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} pending_notifications={@pending_notifications}>
      <.header>
        {@page_title}
        <:subtitle>Use this form to manage project records in your database.</:subtitle>
      </.header>

      <.form for={@form} id="project-form" data-test="project-form" phx-change="validate" phx-submit="save">
        <.input field={@form[:name]} type="text" label="Name" />
        <.input field={@form[:module_name]} type="text" label="Module Name" />
        <.input field={@form[:description]} type="textarea" label="Description" />
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Code repo</span>
          </label>
          <div class="join w-full">
            <input
              type="text"
              id={@form[:code_repo].id}
              name={@form[:code_repo].name}
              value={@form[:code_repo].value}
              class="input input-bordered join-item flex-1"
              placeholder="https://github.com/username/repo-code"
            />
            <button
              type="button"
              phx-click="create_code_repo"
              disabled={is_nil(@project.name) || @project.name == ""}
              class="btn join-item"
            >
              Create
            </button>
          </div>
        </div>
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Docs repo</span>
          </label>
          <div class="join w-full">
            <input
              type="text"
              id={@form[:docs_repo].id}
              name={@form[:docs_repo].name}
              value={@form[:docs_repo].value}
              class="input input-bordered join-item flex-1"
              placeholder="https://github.com/username/repo-docs"
            />
            <button
              type="button"
              phx-click="create_docs_repo"
              disabled={is_nil(@project.name) || @project.name == ""}
              class="btn join-item"
            >
              Create
            </button>
          </div>
        </div>
        <.input field={@form[:client_api_url]} type="text" label="Client API URL" />
        <.input
          field={@form[:google_analytics_property_id]}
          type="text"
          label="Google Analytics Property ID"
        />
        <div class="fieldset mb-2">
          <label>
            <span class="label mb-1">Deploy Key</span>
          </label>
          <input type="hidden" name={@form[:deploy_key].name} value={@deploy_key_value} />
          <div class="join w-full">
            <input
              type="text"
              id={@form[:deploy_key].id}
              value={@deploy_key_value}
              readonly
              class="input input-bordered join-item flex-1"
              placeholder="Click Generate to create a deploy key"
            />
            <button type="button" phx-click="generate_deploy_key" class="btn join-item">
              Generate
            </button>
          </div>
        </div>
        <footer>
          <.button phx-disable-with="Saving...">Save Project</.button>
          <.button navigate={return_path(@current_scope, @return_to, @project)}>Cancel</.button>
        </footer>
      </.form>

      <%!-- Sending domain — its own submits, outside the project form: adding a
            domain registers it with the mail provider and saves immediately. --%>
      <section
        :if={@live_action == :edit and @can_administer_domain?}
        data-test="domain-setup"
        class="mt-10 space-y-4 border-t border-base-300 pt-6"
      >
        <div>
          <h2 class="text-lg font-semibold">Sending domain</h2>
          <p class="text-sm opacity-70">
            Mailboxes send and receive on this domain. Use a subdomain
            (e.g. <span class="font-mono">inbound.yourdomain.com</span>) so it doesn't collide with
            existing mail on your root domain.
          </p>
        </div>

        <div :if={not @domain_verified?} data-test="verify-notice" class="alert alert-warning">
          <.icon name="hero-exclamation-triangle" class="size-5" />
          <span>Verify your sending domain before mail can be sent or received.</span>
        </div>

        <p :if={@domain_error} data-test="domain-error" class="text-error text-sm">{@domain_error}</p>

        <div :if={@domain_verified?} data-test="domain-verified" class="rounded-box bg-base-200 p-4">
          <p class="flex items-center gap-2">
            <span class="opacity-70">Domain:</span>
            <span class="font-mono">{@domain}</span>
            <span class="badge badge-success badge-sm">verified</span>
          </p>
          <.link navigate={~p"/app/mailboxes"} class="link text-sm">Manage mailboxes</.link>
        </div>

        <.form
          :if={is_nil(@domain)}
          for={%{}}
          phx-submit="setup_domain"
          data-test="add-domain-form"
          class="space-y-3 rounded-box bg-base-200 p-4"
        >
          <.input
            name="project[domain]"
            value=""
            type="text"
            label="Sending domain"
            placeholder="inbound.yourdomain.com"
          />
          <.button phx-disable-with="Adding...">Add domain</.button>
        </.form>

        <div
          :if={not @domain_verified? and not is_nil(@domain)}
          data-test="domain-pending"
          class="space-y-3 rounded-box bg-base-200 p-4"
        >
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

          <button
            type="button"
            phx-click="verify_domain"
            data-test="verify-domain"
            class="btn btn-primary btn-sm"
          >
            Verify domain
          </button>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:return_to, return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params)}
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}) do
    project = Projects.get_project!(socket.assigns.current_scope, id)

    socket
    |> assign(:page_title, "Edit Project")
    |> assign(:project, project)
    |> assign(:deploy_key_value, project.deploy_key)
    |> assign(:form, to_form(Projects.change_project(socket.assigns.current_scope, project)))
    |> assign_domain_state(project)
    |> maybe_load_domain_state()
  end

  defp apply_action(socket, :new, _params) do
    project = %Project{account_id: socket.assigns.current_scope.active_account_id}

    socket
    |> assign(:page_title, "New Project")
    |> assign(:project, project)
    |> assign(:deploy_key_value, nil)
    |> assign(:form, to_form(Projects.change_project(socket.assigns.current_scope, project)))
    |> assign_domain_state(nil)
  end

  defp assign_domain_state(socket, project) do
    socket
    |> assign(:can_administer_domain?, Mail.can_administer?(socket.assigns.current_scope))
    |> assign(:domain, project && project.domain)
    |> assign(:domain_verified?, Project.domain_verified?(project))
    |> assign(:dns_records, [])
    |> assign(:domain_status, nil)
    |> assign(:domain_error, nil)
  end

  @impl true
  def handle_event("validate", %{"project" => project_params}, socket) do
    changeset =
      Projects.change_project(
        socket.assigns.current_scope,
        socket.assigns.project,
        project_params
      )

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("generate_deploy_key", _params, socket) do
    # Generate a secure random deploy key (64 bytes = 128 hex characters)
    deploy_key = :crypto.strong_rand_bytes(64) |> Base.encode16(case: :lower)

    {:noreply, assign(socket, deploy_key_value: deploy_key)}
  end

  def handle_event("create_code_repo", params, socket) do
    create_github_repo(socket, :code_repo, params, "")
  end

  def handle_event("create_docs_repo", params, socket) do
    create_github_repo(socket, :docs_repo, params, "-docs")
  end

  def handle_event("save", %{"project" => project_params}, socket) do
    save_project(socket, socket.assigns.live_action, project_params)
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
         |> assign(
           :domain_status,
           if(Project.domain_verified?(project), do: "verified", else: "pending")
         )
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
         |> put_flash(
           :error,
           "Domain not verified yet (status: #{status}). Add the DNS records and try again."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, :domain_error, domain_error_message(reason))}
    end
  end

  defp save_project(socket, :edit, project_params) do
    case Projects.update_project(
           socket.assigns.current_scope,
           socket.assigns.project,
           project_params
         ) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project updated successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, project)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_project(socket, :new, project_params) do
    case Projects.create_project(socket.assigns.current_scope, project_params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project created successfully")
         |> push_navigate(
           to: return_path(socket.assigns.current_scope, socket.assigns.return_to, project)
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(_scope, "index", _project), do: ~p"/app/projects"
  defp return_path(_scope, "show", project), do: ~p"/app/projects/#{project}"

  # A registered-but-unverified domain has DNS records the operator still needs
  # to publish — fetch them from the provider so they're on screen. Skipped on
  # the dead render so the page paints without waiting on an HTTP round trip.
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
      nil ->
        "The email provider returned an error (HTTP #{status}). Check the domain and try again."

      message ->
        "The email provider rejected the request (HTTP #{status}): #{message}"
    end
  end

  defp domain_error_message(_reason),
    do: "Could not reach the email provider. Please try again."

  defp resend_message(%{"message" => message}) when is_binary(message), do: message
  defp resend_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp resend_message(_body), do: nil

  defp create_github_repo(socket, repo_type, params, suffix) do
    project = socket.assigns.project

    case Projects.create_github_repo(
           socket.assigns.current_scope,
           project,
           repo_type,
           params,
           suffix
         ) do
      {:ok, repo_url} ->
        # Update the form with the new repo URL
        attrs = Map.put(%{}, repo_type, repo_url)

        changeset =
          Projects.change_project(
            socket.assigns.current_scope,
            project,
            attrs
          )

        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> put_flash(:info, "Repository created successfully: #{repo_url}")}

      {:error, :github_not_connected} ->
        {:noreply,
         socket
         |> put_flash(:error, "Please connect your GitHub account first")}

      {:error, reason} ->
        require Logger
        Logger.error("Failed to create GitHub repo: #{inspect(reason)}")

        {:noreply,
         socket
         |> put_flash(:error, "Failed to create repository. Please try again.")}
    end
  end
end
