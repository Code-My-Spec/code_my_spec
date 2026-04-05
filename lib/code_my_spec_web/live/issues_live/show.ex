defmodule CodeMySpecWeb.IssuesLive.Show do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Issues

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
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
          <.button navigate={~p"/app/issues"}>
            <.icon name="hero-arrow-left" />
          </.button>
        </:actions>
      </.header>

      <.list>
        <:item title="Description">
          <p class="whitespace-pre-wrap">{@issue.description}</p>
        </:item>
        <:item :if={@issue.story_id} title="Story">#{@issue.story_id}</:item>
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
    </Layouts.app>
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
     |> assign(:page_title, issue.title)
     |> assign(:issue, issue)
     |> assign(:show_form, nil)}
  end

  @impl true
  def handle_event("accept", _params, socket) do
    case Issues.accept_issue(socket.assigns.current_scope, socket.assigns.issue) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign(:issue, issue)
         |> put_flash(:info, "Issue accepted.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to accept issue.")}
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
        {:noreply,
         socket
         |> assign(:issue, issue)
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
        {:noreply,
         socket
         |> assign(:issue, issue)
         |> assign(:show_form, nil)
         |> put_flash(:info, "Issue resolved.")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to resolve issue.")}
    end
  end

  @impl true
  def handle_info({_action, %Issues.Issue{id: id} = issue}, %{assigns: %{issue: %{id: id}}} = socket) do
    {:noreply, assign(socket, :issue, issue)}
  end

  def handle_info({_action, %Issues.Issue{}}, socket) do
    {:noreply, socket}
  end

  defp available_actions(%{status: :incoming}), do: [:accept, :dismiss]
  defp available_actions(%{status: :accepted}), do: [:resolve]
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
