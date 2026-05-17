defmodule CodeMySpecLocalWeb.QaLive do
  @moduledoc """
  Project-wide QA attempts index.

  Renders one row per QA attempt across the active project's stories,
  most-recent first. By default the index shows only the most-recent
  attempt per story and hides invalidated attempts; the engineer can
  toggle filters to include older attempts and/or invalidated attempts.
  """

  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Projects
  alias CodeMySpec.Qa
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       attempts: [],
       include_older: false,
       include_invalidated: false,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name}, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      socket =
        socket
        |> assign(
          project: project,
          scope: scope,
          page_title: "#{project.name} — QA",
          error: nil
        )
        |> load_attempts()

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("toggle_older", _params, socket) do
    socket
    |> update(:include_older, &(!&1))
    |> load_attempts()
    |> then(&{:noreply, &1})
  end

  def handle_event("toggle_invalidated", _params, socket) do
    socket
    |> update(:include_invalidated, &(!&1))
    |> load_attempts()
    |> then(&{:noreply, &1})
  end

  defp load_attempts(%{assigns: %{scope: scope}} = socket) do
    attempts =
      Qa.list_project_attempts(scope,
        include_older: socket.assigns.include_older,
        include_invalidated: socket.assigns.include_invalidated
      )

    assign(socket, attempts: attempts)
  end

  defp load_attempts(socket), do: socket

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:qa}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project}>
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-3xl font-bold">
            QA <span class="text-base-content/50 font-normal text-xl">({length(@attempts)})</span>
          </h1>
        </div>

        <div class="flex flex-wrap gap-3 mb-6">
          <label class="label cursor-pointer gap-2">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              data-role="qa-index-filter-older"
              phx-click="toggle_older"
              checked={@include_older}
            />
            <span class="label-text">Include older attempts</span>
          </label>

          <label class="label cursor-pointer gap-2">
            <input
              type="checkbox"
              class="checkbox checkbox-sm"
              data-role="qa-index-filter-invalidated"
              phx-click="toggle_invalidated"
              checked={@include_invalidated}
            />
            <span class="label-text">Include invalidated</span>
          </label>
        </div>

        <div
          :if={@attempts == []}
          class="text-base-content/50 py-12 text-center border border-dashed border-base-300 rounded-box"
        >
          No QA attempts recorded.
        </div>

        <div :if={@attempts != []} class="overflow-x-auto rounded-box border border-base-300">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Status</th>
                <th>Story</th>
                <th>Agent</th>
                <th class="hidden md:table-cell">Scenarios</th>
                <th>Issues</th>
                <th>Submitted</th>
              </tr>
            </thead>
            <tbody>
              <.attempt_row
                :for={attempt <- @attempts}
                attempt={attempt}
                project={@project}
              />
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :attempt, :map, required: true
  attr :project, :map, required: true

  defp attempt_row(assigns) do
    invalidated? = match?([_ | _], assigns.attempt.invalidations)
    assigns = assign(assigns, invalidated?: invalidated?)

    ~H"""
    <tr class={["hover", @invalidated? && "opacity-60"]}>
      <td>
        <span class={["badge badge-sm", status_badge(@attempt.status)]}>
          {@attempt.status}
        </span>
        <span :if={@invalidated?} class="badge badge-sm badge-neutral ml-1 line-through">
          invalidated
        </span>
      </td>
      <td class="font-medium">
        <.link
          navigate={~p"/projects/#{@project.name}/stories/#{@attempt.story_id}"}
          class="link link-hover"
        >
          {story_title(@attempt)}
        </.link>
      </td>
      <td><code class="text-xs">{@attempt.agent_id}</code></td>
      <td class="hidden md:table-cell text-sm text-base-content/70">
        <div :for={scenario <- @attempt.scenarios} class="truncate max-w-xs">
          <span class={["badge badge-xs mr-1", status_badge(scenario.status)]}>
            {scenario.status}
          </span>
          {scenario.name}
        </div>
        <div
          :for={inv <- @attempt.invalidations}
          class="mt-1 text-error/80 text-xs italic"
        >
          {inv.reason}
        </div>
      </td>
      <td class="text-sm">{length(@attempt.issue_ids)}</td>
      <td class="text-sm text-base-content/60">{format_dt(@attempt.submitted_at)}</td>
    </tr>
    """
  end

  defp status_badge(:pass), do: "badge-success"
  defp status_badge(:partial), do: "badge-warning"
  defp status_badge(:fail), do: "badge-error"
  defp status_badge(_), do: "badge-neutral"

  defp story_title(%{story: %{title: title}}) when is_binary(title), do: title
  defp story_title(%{story_id: id}), do: "story ##{id}"

  defp format_dt(nil), do: ""

  defp format_dt(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  end

  defp format_dt(other), do: to_string(other)
end
