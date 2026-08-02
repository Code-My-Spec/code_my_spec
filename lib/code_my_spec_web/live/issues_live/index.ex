defmodule CodeMySpecWeb.IssuesLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Issues

  @statuses ~w(all incoming accepted dismissed resolved)
  @severities ~w(all critical high medium low info)

  @impl true
  def render(assigns) do
    ~H"""
      <.header>
        Issues
        <:actions>
          <form phx-change="filter" class="flex items-center gap-2">
            <select class="select select-sm select-bordered" name="status">
              <option :for={s <- @status_options} value={s} selected={s == @filter_status}>
                {String.capitalize(s)}
              </option>
            </select>
            <select class="select select-sm select-bordered" name="severity">
              <option :for={s <- @severity_options} value={s} selected={s == @filter_severity}>
                {String.capitalize(s)}
              </option>
            </select>
          </form>
        </:actions>
      </.header>

      <div :if={@issues == []} class="text-center py-12 text-base-content/60">
        No issues found.
      </div>

      <div id="issues" class="space-y-4 mt-6">
        <div
          :for={issue <- @issues}
          id={"issue-#{issue.id}"}
          class="card bg-base-100 shadow-md cursor-pointer hover:shadow-lg transition-shadow"
          phx-click={JS.navigate(path(@socket, ~p"/app/projects/#{@project.id}/issues/#{issue.id}"))}
        >
          <div class="card-body py-4">
            <div class="flex items-start justify-between gap-4">
              <div class="flex-1 min-w-0">
                <h2 class="card-title text-base">{issue.title}</h2>
                <p class="text-sm text-base-content/70 mt-1 line-clamp-2">
                  {issue.description}
                </p>
              </div>
              <div class="flex items-center gap-2 shrink-0">
                <.badge color={severity_color(issue.severity)}>
                  {issue.severity}
                </.badge>
                <.badge color={status_color(issue.status)}>
                  {issue.status}
                </.badge>
              </div>
            </div>
            <div :if={issue.story_id || issue.scope != :app} class="flex gap-2 mt-2 text-xs text-base-content/50">
              <span :if={issue.story_id}>Story #{issue.story_id}</span>
              <span :if={issue.scope != :app} class="badge badge-xs badge-outline">{issue.scope}</span>
            </div>
          </div>
        </div>
      </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Issues.subscribe(socket.assigns.current_scope)
    end

    {:ok,
     socket
     |> assign(:section, :issues)
     |> assign(:page_title, "Issues")
     |> assign(:filter_status, "all")
     |> assign(:filter_severity, "all")
     |> assign(:status_options, @statuses)
     |> assign(:severity_options, @severities)}
  end

  # Filters live in the query string, not just in assigns — a filtered list is
  # then a link you can send someone, and it survives a reload.
  @impl true
  def handle_params(params, _uri, %{assigns: %{scope: %{}}} = socket) do
    {:noreply,
     socket
     |> assign(:filter_status, param(params["status"], @statuses, socket.assigns.filter_status))
     |> assign(
       :filter_severity,
       param(params["severity"], @severities, socket.assigns.filter_severity)
     )
     |> load_issues()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp param(value, allowed, fallback) when is_binary(value) do
    if value in allowed, do: value, else: fallback
  end

  defp param(_value, _allowed, fallback), do: fallback

  @impl true
  def handle_event("filter", params, socket) do
    query =
      [
        status: params["status"] || socket.assigns.filter_status,
        severity: params["severity"] || socket.assigns.filter_severity
      ]
      |> Enum.reject(fn {_k, v} -> v in [nil, "all"] end)

    {:noreply,
     push_patch(socket,
       to: path(socket, ~p"/app/projects/#{socket.assigns.slug}/issues?#{query}")
     )}
  end

  @impl true
  def handle_info({_action, %Issues.Issue{}}, socket) do
    {:noreply, load_issues(socket)}
  end

  defp load_issues(socket) do
    scope = socket.assigns.current_scope
    filters = build_filters(socket.assigns)
    assign(socket, :issues, Issues.list_filtered(scope, Map.new(filters)))
  end

  defp build_filters(assigns) do
    []
    |> maybe_add(:status, assigns.filter_status)
    |> maybe_add(:severity, assigns.filter_severity)
  end

  defp maybe_add(filters, _key, "all"), do: filters
  defp maybe_add(filters, key, value), do: [{key, String.to_existing_atom(value)} | filters]

  defp severity_color(:critical), do: "error"
  defp severity_color(:high), do: "warning"
  defp severity_color(:medium), do: "info"
  defp severity_color(:low), do: "ghost"
  defp severity_color(:info), do: "ghost"
  defp severity_color(_), do: "ghost"

  defp status_color(:incoming), do: "warning"
  defp status_color(:accepted), do: "info"
  defp status_color(:resolved), do: "success"
  defp status_color(:dismissed), do: "ghost"
  defp status_color(_), do: "ghost"
end
