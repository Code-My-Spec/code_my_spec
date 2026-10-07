defmodule CodeMySpecWeb.IssuesLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Issues
  alias CodeMySpec.Stories
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      {@issue.title}
      <:subtitle>
        <div class="flex items-center gap-2 mt-1">
          <.badge color={severity_color(@issue.severity)}>{@issue.severity}</.badge>
          <.badge color={status_color(@issue.status)}>{@issue.status}</.badge>
          <span :if={@issue.scope != :app} class="badge badge-sm badge-outline">{@issue.scope}</span>
        </div>
      </:subtitle>
      <:actions>
        <.button navigate={path(@socket, ~p"/app/projects/#{@project.id}/issues")}>
          <.icon name="hero-arrow-left" />
        </.button>
      </:actions>
    </.header>

    <.list>
      <:item title="Description">
        <p class="whitespace-pre-wrap">{@issue.description}</p>
      </:item>
      <:item :if={has_screenshot?(@issue) and @serves_attachments?} title="Screenshot">
        <a
          href={path(@socket, ~p"/app/issues/#{@issue.id}/screenshot")}
          target="_blank"
          rel="noopener"
        >
          <img
            src={path(@socket, ~p"/app/issues/#{@issue.id}/screenshot")}
            alt="Reported screenshot"
            class="max-h-96 rounded border border-base-300"
          />
        </a>
      </:item>
      <:item :if={@story} title="Story">
        <.link
          navigate={path(@socket, ~p"/app/projects/#{@project.id}/stories/#{@story.number}")}
          class="link link-hover"
        >
          Story {@story.number} — {@story.title}
        </.link>
      </:item>
      <:item :if={@issue.source_path} title="Source path">
        <code class="text-sm">{@issue.source_path}</code>
      </:item>
      <:item :if={@issue.resolution} title="Resolution">
        <p class="whitespace-pre-wrap">{@issue.resolution}</p>
      </:item>
      <:item title="Created">{Calendar.strftime(@issue.inserted_at, "%b %d, %Y %H:%M")}</:item>
    </.list>

    <div :if={available_actions(@issue) != []} class="mt-8">
      <h3 class="text-lg font-semibold mb-4">Actions</h3>
      <div class="flex gap-2">
        <button
          :if={:accept in available_actions(@issue)}
          phx-click="accept"
          class="btn btn-sm btn-primary"
        >
          Accept
        </button>
        <button
          :if={:dismiss in available_actions(@issue)}
          phx-click="show_dismiss_form"
          class="btn btn-sm btn-ghost"
        >
          Dismiss
        </button>
        <button
          :if={:resolve in available_actions(@issue)}
          phx-click="show_resolve_form"
          class="btn btn-sm btn-success"
        >
          Resolve
        </button>
      </div>

      <form
        :if={:assign in available_actions(@issue)}
        phx-submit="assign_to_working_copy"
        data-test="issue-assignment-form"
        class="mt-4 flex items-end gap-2"
      >
        <.input
          type="select"
          name="working_copy_id"
          label="Assign to working copy"
          prompt="Choose a working copy"
          value=""
          options={Enum.map(@working_copies, &{WorkingCopies.display_name(&1), &1.id})}
        />
        <button type="submit" class="btn btn-sm btn-primary">Assign</button>
      </form>

      <button
        :if={@issue.status == :accepted and @issue.assigned_working_copy_id != nil}
        phx-click="unassign_from_working_copy"
        data-test="unassign-issue-from-working-copy"
        class="btn btn-sm btn-ghost mt-4"
      >
        Remove from working copy
      </button>

      <form
        :if={@show_form == :dismiss}
        phx-submit="dismiss"
        class="mt-4 space-y-3"
      >
        <.input
          type="textarea"
          name="reason"
          label="Dismissal reason"
          value=""
          required
        />
        <div class="flex gap-2">
          <button type="submit" class="btn btn-sm btn-ghost">Dismiss issue</button>
          <button type="button" phx-click="hide_form" class="btn btn-sm btn-outline">Cancel</button>
        </div>
      </form>

      <form
        :if={@show_form == :resolve}
        phx-submit="resolve"
        class="mt-4 space-y-3"
      >
        <.input
          type="textarea"
          name="resolution"
          label="Resolution"
          value=""
          required
        />
        <div class="flex gap-2">
          <button type="submit" class="btn btn-sm btn-success">Resolve issue</button>
          <button type="button" phx-click="hide_form" class="btn btn-sm btn-outline">Cancel</button>
        </div>
      </form>
    </div>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Issues.subscribe(socket.assigns.current_scope)
    end

    issue = Issues.get_issue!(socket.assigns.current_scope, id)

    {:ok,
     socket
     |> assign(:section, :issues)
     |> assign(:page_title, issue.title)
     |> assign_issue(issue)
     |> assign(:working_copies, WorkingCopies.list_harnesses(socket.assigns.current_scope))
     |> assign(:show_form, nil)}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    case Issues.accept_issue(socket.assigns.current_scope, socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign_issue(issue)
         |> put_flash(:info, "Issue accepted.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to accept issue.")}
    end
  end

  @impl true
  def handle_event("assign_to_working_copy", %{"working_copy_id" => working_copy_id}, socket)
      when working_copy_id != "" do
    case Agents.assign_issue_to_working_copy(
           socket.assigns.current_scope,
           socket.assigns.issue.id,
           working_copy_id
         ) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign_issue(issue)
         |> put_flash(:info, "Issue assigned.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "That working copy is not on this project.")}

      {:error, :no_team} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "That working copy has no coding or QA agent to hold the issue."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to assign issue.")}
    end
  end

  def handle_event("assign_to_working_copy", _params, socket), do: {:noreply, socket}

  def handle_event("unassign_from_working_copy", _params, socket) do
    case Agents.assign_issue_to_working_copy(
           socket.assigns.current_scope,
           socket.assigns.issue.id,
           nil
         ) do
      {:ok, issue} ->
        {:noreply,
         socket |> assign_issue(issue) |> put_flash(:info, "Issue removed from working copy.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to remove issue from working copy.")}
    end
  end

  @impl true
  def handle_event("show_dismiss_form", _params, socket) do
    {:noreply, assign(socket, :show_form, :dismiss)}
  end

  @impl true
  def handle_event("show_resolve_form", _params, socket) do
    {:noreply, assign(socket, :show_form, :resolve)}
  end

  @impl true
  def handle_event("hide_form", _params, socket) do
    {:noreply, assign(socket, :show_form, nil)}
  end

  @impl true
  def handle_event("dismiss", %{"reason" => reason}, socket) do
    case Issues.dismiss_issue(socket.assigns.current_scope, socket.assigns.issue, reason) do
      {:ok, issue} ->
        {:ok, _released} = TaskOwner.issue_closed(socket.assigns.current_scope, issue)

        {:noreply,
         socket
         |> assign_issue(issue)
         |> assign(:show_form, nil)
         |> put_flash(:info, "Issue dismissed.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to dismiss issue.")}
    end
  end

  @impl true
  def handle_event("resolve", %{"resolution" => resolution}, socket) do
    case Issues.resolve_issue(socket.assigns.current_scope, socket.assigns.issue, resolution) do
      {:ok, issue} ->
        {:ok, _released} = TaskOwner.issue_closed(socket.assigns.current_scope, issue)

        {:noreply,
         socket
         |> assign_issue(issue)
         |> assign(:show_form, nil)
         |> put_flash(:info, "Issue resolved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve issue.")}
    end
  end

  @impl true
  def handle_info(
        {_action, %Issues.Issue{id: id} = issue},
        %{assigns: %{issue: %{id: id}}} = socket
      ) do
    {:noreply, assign_issue(socket, issue)}
  end

  def handle_info({_action, %Issues.Issue{}}, socket) do
    {:noreply, socket}
  end

  defp assign_issue(socket, issue) do
    socket
    |> assign(:issue, issue)
    |> assign(:story, issue_story(socket.assigns.current_scope, issue))
  end

  defp issue_story(_scope, %{story_id: nil}), do: nil
  defp issue_story(scope, %{story_id: story_id}), do: Stories.get_story(scope, story_id)

  defp has_screenshot?(%{attachments: attachments}) when is_list(attachments) do
    Enum.any?(attachments, &(is_map(&1) and &1["type"] == "screenshot"))
  end

  defp has_screenshot?(_issue), do: false

  defp available_actions(%{status: :incoming}), do: [:accept, :dismiss]
  defp available_actions(%{status: :accepted}), do: [:assign, :resolve]
  defp available_actions(_), do: []

  defp severity_color(:critical), do: "error"
  defp severity_color(:high), do: "warning"
  defp severity_color(:medium), do: "info"
  defp severity_color(_), do: "ghost"

  defp status_color(:incoming), do: "warning"
  defp status_color(:accepted), do: "info"
  defp status_color(:resolved), do: "success"
  defp status_color(:dismissed), do: "ghost"
  defp status_color(_), do: "ghost"
end
