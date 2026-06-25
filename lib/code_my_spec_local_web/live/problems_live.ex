defmodule CodeMySpecLocalWeb.ProblemsLive do
  @moduledoc """
  Persisted Problems viewer.

  Sibling surface to `/files` and `/configuration`: lists every Problem row
  for the project so the engineer can see what each analyzer surfaced last
  turn — including problems persisted in `:dont_block` mode and advisory
  problems excluded from the stop block decision.

  Read-only. Problems are written by the validation pipeline; this view
  just exposes them.
  """
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.Problems
  alias CodeMySpec.Projects
  alias CodeMySpec.Users.Scope

  @per_page 25
  @sources ~w(compiler credo exunit spex spec_validation qa_validation)

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       page: 1,
       filter: :all,
       result: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(%{"project_name" => name} = params, _uri, socket) do
    case load_project_and_scope(name) do
      {:ok, project, scope} ->
        page = parse_page(params["page"])
        filter = parse_filter(params["filter"])

        result =
          Problems.list_problems_paginated(scope,
            page: page,
            per_page: @per_page,
            filter: filter
          )

        {:noreply,
         assign(socket,
           project: project,
           scope: scope,
           slug: project_slug(project),
           page: page,
           filter: filter,
           result: result,
           page_title: "#{project.name} — Problems",
           error: nil
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: "Failed to load project: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("clear", _params, %{assigns: %{scope: scope, filter: filter}} = socket) do
    {:ok, count} =
      case filter do
        :all -> Problems.clear_project_problems(scope)
        source -> Problems.clear_problems_for_source(scope, [source: source], :all)
      end

    result =
      Problems.list_problems_paginated(scope,
        page: 1,
        per_page: @per_page,
        filter: filter
      )

    label = if filter == :all, do: "all sources", else: filter

    {:noreply,
     socket
     |> assign(page: 1, result: result)
     |> put_flash(:info, "Cleared #{count} problem(s) from #{label}.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:problems}
      page_title={assigns[:page_title]}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project && @result}>
        <div class="mb-6">
          <h1 class="text-3xl font-bold">Problems</h1>
          <p class="text-base-content/60 mt-1">
            Every problem the validation pipeline persisted, ordered by severity.
            Filter by source to see what each analyzer flagged.
          </p>
        </div>

        <div class="flex flex-wrap items-center gap-2 mb-4" data-test="problems-filters">
          <.link
            patch={problems_path(@slug, page: 1, filter: :all)}
            data-test="filter-all"
            class={"btn btn-sm " <> if(@filter == :all, do: "btn-primary", else: "btn-ghost")}
          >
            All ({@result.unfiltered_count})
          </.link>
          <.link
            :for={source <- sources()}
            patch={problems_path(@slug, page: 1, filter: source)}
            data-test={"filter-" <> source}
            class={"btn btn-sm " <> if(@filter == source, do: "btn-primary", else: "btn-ghost")}
          >
            {source} ({Map.get(@result.counts_by_source, source, 0)})
          </.link>

          <button
            :if={@result.problems != []}
            type="button"
            phx-click={show_confirm("clear-problems-dialog")}
            data-test="clear-problems"
            class="btn btn-sm btn-error btn-outline ml-auto"
          >
            Clear
          </button>
        </div>

        <.confirm_dialog
          id="clear-problems-dialog"
          title={
            if @filter == :all,
              do: "Clear all problems?",
              else: "Clear all #{@filter} problems?"
          }
          message="They'll repopulate the next time the validation pipeline runs."
          confirm_label="Clear"
          on_confirm={JS.push("clear")}
        />

        <div class="overflow-x-auto">
          <table class="table table-zebra table-sm" data-test="problems-table">
            <thead>
              <tr>
                <th>Severity</th>
                <th>Source</th>
                <th>File</th>
                <th>Line</th>
                <th>Message</th>
                <th>Category</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={problem <- @result.problems}
                data-test="problem-row"
                data-problem-source={problem.source}
                data-problem-severity={Atom.to_string(problem.severity || :info)}
                data-problem-file-path={problem.file_path}
              >
                <td data-test="problem-severity">
                  <.severity_badge severity={problem.severity} />
                </td>
                <td data-test="problem-source" class="font-mono text-xs">{problem.source}</td>
                <td data-test="problem-file" class="font-mono text-xs">{problem.file_path || "—"}</td>
                <td class="font-mono text-xs">{problem.line || ""}</td>
                <td data-test="problem-message" class="text-sm">{problem.message}</td>
                <td class="text-xs opacity-70">{problem.category || ""}</td>
              </tr>
              <tr :if={@result.problems == []}>
                <td colspan="6" class="text-center opacity-60 py-8" data-test="problems-empty">
                  No problems match the current filter.
                </td>
              </tr>
            </tbody>
          </table>
        </div>

        <nav
          :if={@result.total_pages > 1}
          data-test="pagination"
          class="flex justify-between items-center mt-4"
        >
          <span class="text-sm opacity-60">
            Page {@result.page} of {@result.total_pages} ({@result.total_count} problems)
          </span>
          <div class="join">
            <.link
              :if={@result.page > 1}
              patch={problems_path(@slug, page: @result.page - 1, filter: @filter)}
              data-test="prev-page"
              class="join-item btn btn-sm"
            >
              ← Prev
            </.link>
            <.link
              :if={@result.page < @result.total_pages}
              patch={problems_path(@slug, page: @result.page + 1, filter: @filter)}
              data-test="next-page"
              class="join-item btn btn-sm"
            >
              Next →
            </.link>
          </div>
        </nav>
      </div>
    </Layouts.app>
    """
  end

  attr :severity, :any, required: true

  defp severity_badge(assigns) do
    ~H"""
    <span :if={@severity == :error} class="badge badge-error badge-sm">error</span>
    <span :if={@severity == :warning} class="badge badge-warning badge-sm">warning</span>
    <span :if={@severity == :info} class="badge badge-info badge-sm">info</span>
    <span :if={is_nil(@severity)} class="badge badge-ghost badge-sm">—</span>
    """
  end

  defp sources, do: @sources

  defp parse_page(nil), do: 1

  defp parse_page(raw) when is_binary(raw) do
    case Integer.parse(raw) do
      {n, _} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: 1

  defp parse_filter(value) when value in @sources, do: value
  defp parse_filter(_), do: :all

  defp problems_path(slug, opts) do
    page = Keyword.get(opts, :page, 1)
    filter = Keyword.get(opts, :filter, :all)

    base = "/projects/#{slug}/problems"

    params = []
    params = if page > 1, do: [{"page", page} | params], else: params
    params = if filter != :all, do: [{"filter", filter} | params], else: params

    case params do
      [] -> base
      _ -> base <> "?" <> URI.encode_query(params)
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end
end
