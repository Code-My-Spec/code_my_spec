defmodule CodeMySpecLocalWeb.IssuesLive.Show do
  @moduledoc """
  Displays a single issue with full details.

  Renders triage actions (Accept / Dismiss / Resolve) gated by the issue's
  current status. Dismiss and Resolve open a modal that captures the
  required reason / resolution; Accept is a single click.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Issues
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()
    {:ok, assign(socket, projects: projects, project: nil, issue: nil, error: nil)}
  end

  @impl true
  def handle_params(%{"project_name" => name, "id" => id}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      slug = project_slug(project)

      case Issues.get_issue(scope, id) do
        nil ->
          {:noreply, assign(socket, project: project, slug: slug, error: "Issue not found: #{id}")}

        issue ->
          {:noreply,
           assign(socket,
             project: project,
             scope: scope,
             slug: slug,
             issue: issue,
             page_title: "#{project.name} — #{issue.title}",
             error: nil
           )}
      end
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("accept", _params, socket) do
    case Issues.accept_issue(socket.assigns.scope, socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply, socket |> assign(issue: issue) |> put_flash(:info, "Issue accepted.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not accept: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss", %{"reason" => reason}, socket) do
    case Issues.dismiss_issue(socket.assigns.scope, socket.assigns.issue, reason) do
      {:ok, issue} ->
        {:noreply, socket |> assign(issue: issue) |> put_flash(:info, "Issue dismissed.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not dismiss: #{format_errors(changeset)}")}
    end
  end

  def handle_event("resolve", %{"resolution" => resolution}, socket) do
    case Issues.resolve_issue(socket.assigns.scope, socket.assigns.issue, resolution) do
      {:ok, issue} ->
        {:noreply, socket |> assign(issue: issue) |> put_flash(:info, "Issue resolved.")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Could not resolve: #{format_errors(changeset)}")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:issues}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @issue}>
        <div class="mb-4">
          <.link navigate={~p"/projects/#{@slug}/issues"} class="btn btn-ghost btn-sm gap-1">
            ← Issues
          </.link>
        </div>

        <div class="flex items-start justify-between gap-4 mb-6">
          <h1 class="text-2xl font-bold">{@issue.title}</h1>
          <div class="flex gap-2 shrink-0">
            <span class={"badge #{status_badge(@issue.status)}"}>{@issue.status}</span>
            <span class={"badge badge-outline #{severity_badge(@issue.severity)}"}>{@issue.severity}</span>
          </div>
        </div>

        <div :if={@issue.status in [:incoming, :accepted]} class="flex gap-2 mb-6" data-role="issue-actions">
          <button
            :if={@issue.status == :incoming}
            type="button"
            class="btn btn-sm btn-success"
            data-role="issue-accept"
            phx-click="accept"
          >
            Accept
          </button>
          <button
            :if={@issue.status == :accepted}
            type="button"
            class="btn btn-sm btn-primary"
            data-role="issue-resolve"
            phx-click={show_confirm("resolve-issue-#{@issue.id}")}
          >
            Resolve
          </button>
          <button
            :if={@issue.status in [:incoming, :accepted]}
            type="button"
            class="btn btn-sm btn-neutral"
            data-role="issue-dismiss"
            phx-click={show_confirm("dismiss-issue-#{@issue.id}")}
          >
            Dismiss
          </button>
        </div>

        <.text_prompt_dialog
          :if={@issue.status in [:incoming, :accepted]}
          id={"dismiss-issue-#{@issue.id}"}
          title="Dismiss this issue?"
          field_label="Reason"
          field_name="reason"
          placeholder="Explain why this issue is not actionable"
          submit_label="Dismiss"
          submit_event="dismiss"
        />

        <.text_prompt_dialog
          :if={@issue.status == :accepted}
          id={"resolve-issue-#{@issue.id}"}
          title="Resolve this issue?"
          field_label="Resolution"
          field_name="resolution"
          placeholder="Describe how the issue was fixed"
          submit_label="Resolve"
          submit_event="resolve"
        />

        <div class="grid grid-cols-2 sm:grid-cols-4 gap-4 mb-6 text-sm">
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wide">Scope</div>
            <div>{@issue.scope}</div>
          </div>
          <div>
            <div class="text-xs text-base-content/50 uppercase tracking-wide">Created</div>
            <div>{Calendar.strftime(@issue.inserted_at, "%b %d, %Y")}</div>
          </div>
          <div :if={@issue.story_id}>
            <div class="text-xs text-base-content/50 uppercase tracking-wide">Story</div>
            <.link navigate={~p"/projects/#{@slug}/stories/#{@issue.story_id}"} class="link link-primary">
              #{@issue.story_id}
            </.link>
          </div>
          <div :if={@issue.source_path}>
            <div class="text-xs text-base-content/50 uppercase tracking-wide">Source</div>
            <code class="text-sm">{@issue.source_path}</code>
          </div>
        </div>

        <div :if={@issue.description && @issue.description != ""} class="mb-6">
          <h2 class="text-lg font-semibold mb-2">Description</h2>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body whitespace-pre-wrap text-sm">
              {@issue.description}
            </div>
          </div>
        </div>

        <div :if={@issue.resolution && @issue.resolution != ""}>
          <h2 class="text-lg font-semibold mb-2">Resolution</h2>
          <div class="card bg-base-200 border border-base-300">
            <div class="card-body whitespace-pre-wrap text-sm">
              {@issue.resolution}
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp status_badge(:incoming), do: "badge-info"
  defp status_badge(:accepted), do: "badge-success"
  defp status_badge(:dismissed), do: "badge-neutral"
  defp status_badge(:resolved), do: "badge-primary"
  defp status_badge(_), do: ""

  defp severity_badge(:critical), do: "badge-error"
  defp severity_badge(:high), do: "badge-warning"
  defp severity_badge(:medium), do: "badge-info"
  defp severity_badge(:low), do: "badge-neutral"
  defp severity_badge(:info), do: "badge-ghost"
  defp severity_badge(_), do: ""

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp format_errors(%Ecto.Changeset{} = changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _}} -> "#{field} #{msg}" end)
  end

  defp format_errors(other), do: inspect(other)

  # Reusable text-input modal — used for Dismiss reason and Resolve
  # resolution. Submits via the named LiveView event with a single
  # string field. Renders inline (sibling to the trigger button) and
  # is shown via `show_confirm/2`.
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :field_label, :string, required: true
  attr :field_name, :string, required: true
  attr :placeholder, :string, default: ""
  attr :submit_label, :string, required: true
  attr :submit_event, :string, required: true

  defp text_prompt_dialog(assigns) do
    ~H"""
    <dialog id={@id} class="modal" data-role="confirm-dialog">
      <div class="modal-box">
        <h3 class="text-lg font-bold">{@title}</h3>
        <form phx-submit={JS.push(@submit_event) |> hide_dialog(@id)} class="space-y-4 mt-4">
          <label class="form-control">
            <div class="label">
              <span class="label-text">{@field_label}</span>
            </div>
            <textarea
              name={@field_name}
              rows="4"
              class="textarea textarea-bordered w-full"
              placeholder={@placeholder}
              required
              data-role={"#{@field_name}-input"}
            ></textarea>
          </label>
          <div class="modal-action">
            <button
              type="button"
              class="btn"
              data-role="confirm-cancel"
              phx-click={hide_dialog(@id)}
            >
              Cancel
            </button>
            <button
              type="submit"
              class="btn btn-primary"
              data-role="confirm-confirm"
            >
              {@submit_label}
            </button>
          </div>
        </form>
      </div>
      <form method="dialog" class="modal-backdrop">
        <button type="button" aria-label="close" phx-click={hide_dialog(@id)}>close</button>
      </form>
    </dialog>
    """
  end

  defp hide_dialog(js \\ %JS{}, id), do: JS.remove_class(js, "modal-open", to: "#" <> id)
end
