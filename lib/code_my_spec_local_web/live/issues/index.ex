defmodule CodeMySpecLocalWeb.IssuesLive.Index do
  @moduledoc """
  Lists issues with optional filtering by status, severity, and scope.

  Filters live in the URL query string so they survive refreshes and
  back-navigations. The view subscribes to the per-account issues
  PubSub topic and re-runs the filtered list on every create /
  accept / dismiss / resolve / update broadcast, so external
  mutations (MCP tools, the show page) reach the table without a
  manual refresh.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Issues
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       issues: [],
       filters: %{},
       error: nil,
       subscribed_account_id: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name} = params, _uri, socket) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      filters = parse_filters(params)
      issues = Issues.list_filtered(scope, filters)

      socket =
        socket
        |> maybe_subscribe(scope)
        |> assign(
          project: project,
          scope: scope,
          slug: project_slug(project),
          issues: issues,
          filters: filters,
          page_title: "#{project.name} — Issues",
          error: nil
        )

      {:noreply, socket}
    else
      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("filter", params, socket) do
    filters = parse_filters(params)
    {:noreply, push_patch(socket, to: filter_path(socket.assigns.slug, filters))}
  end

  @impl true
  def handle_info({event, %Issues.Issue{}}, socket)
      when event in [:created, :accepted, :dismissed, :resolved, :updated] do
    issues = Issues.list_filtered(socket.assigns.scope, socket.assigns.filters)
    {:noreply, assign(socket, :issues, issues)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

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

      <div :if={!@error && @project}>
        <div class="flex items-center justify-between mb-6">
          <h1 class="text-3xl font-bold">Issues <span class="text-base-content/50 font-normal text-xl">({length(@issues)})</span></h1>
        </div>

        <form phx-change="filter" class="flex flex-wrap gap-2 mb-6">
          <select name="status" class="select select-sm select-bordered">
            <option value="">All statuses</option>
            <option :for={s <- ~w(incoming accepted dismissed resolved)} value={s} selected={@filters[:status] == String.to_existing_atom(s)}>
              {s}
            </option>
          </select>

          <select name="severity" class="select select-sm select-bordered">
            <option value="">All severities</option>
            <option :for={s <- ~w(critical high medium low info)} value={s} selected={@filters[:severity] == String.to_existing_atom(s)}>
              {s}
            </option>
          </select>

          <select name="scope" class="select select-sm select-bordered">
            <option value="">All scopes</option>
            <option :for={s <- ~w(app qa docs framework)} value={s} selected={@filters[:scope] == String.to_existing_atom(s)}>
              {s}
            </option>
          </select>
        </form>

        <div :if={@issues == []} class="text-base-content/50 py-12 text-center border border-dashed border-base-300 rounded-box">
          No issues found.
        </div>

        <div :if={@issues != []} class="overflow-x-auto rounded-box border border-base-300">
          <table class="table table-zebra">
            <thead>
              <tr>
                <th>Status</th>
                <th>Severity</th>
                <th>Title</th>
                <th>Scope</th>
                <th class="hidden sm:table-cell">Created</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={issue <- @issues}
                class="hover cursor-pointer"
                phx-click={JS.navigate("/app/projects/#{@slug}/issues/#{issue.id}")}
              >
                <td><span class={"badge badge-sm #{status_badge(issue.status)}"}>{issue.status}</span></td>
                <td><span class={"badge badge-sm badge-outline #{severity_badge(issue.severity)}"}>{issue.severity}</span></td>
                <td class="font-medium">{issue.title}</td>
                <td>{issue.scope}</td>
                <td class="hidden sm:table-cell text-base-content/50 text-sm">
                  {Calendar.strftime(issue.inserted_at, "%b %d")}
                </td>
              </tr>
            </tbody>
          </table>
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

  defp parse_filters(params) do
    Enum.reduce([:status, :severity, :scope], %{}, fn key, acc ->
      case parse_atom(params[Atom.to_string(key)]) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp parse_atom(nil), do: nil
  defp parse_atom(s) when is_binary(s) and s != "", do: String.to_existing_atom(s)
  defp parse_atom(_), do: nil

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp filter_path(slug, filters) do
    query =
      filters
      |> Enum.map(fn {k, v} -> {Atom.to_string(k), Atom.to_string(v)} end)
      |> URI.encode_query()

    case query do
      "" -> "/app/projects/#{slug}/issues"
      q -> "/app/projects/#{slug}/issues?#{q}"
    end
  end

  defp maybe_subscribe(socket, %Scope{active_account_id: account_id})
       when is_binary(account_id) do
    cond do
      not connected?(socket) ->
        socket

      socket.assigns.subscribed_account_id == account_id ->
        socket

      true ->
        Issues.subscribe(%Scope{active_account_id: account_id})
        assign(socket, :subscribed_account_id, account_id)
    end
  end

  defp maybe_subscribe(socket, _scope), do: socket
end
