defmodule CodeMySpecWeb.ProblemsLive do
  @moduledoc """
  Persisted Problems viewer.

  Sibling surface to `/files` and `/configuration`: lists every Problem row
  for the project so the engineer can see what each analyzer surfaced. Nothing
  here blocks a stop; problems gate at promotion.

  Read-only. Problems are written by the validation pipeline; this view
  just exposes them.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.WorkingCopies
  import CodeMySpecWeb.HarnessPicker
  alias CodeMySpec.Problems
  alias CodeMySpecWeb.ProblemCharts

  @per_page 25
  @top_files 10
  @sources ~w(compiler credo exunit spex qa_validation)

  @impl true
  def mount(_params, _session, socket) do
    # Files and problems belong to a working copy. Without this the page shows
    # every checkout's rows merged — the same path once per checkout, one
    # checkout's failures against another's code — so it reads as the most
    # recently active one until there is a picker to say otherwise.
    # The working copy is resolved per-request in `handle_params/3`, because it
    # travels in the URL.

    {:ok,
     assign(socket,
       section: :problems,
       harnesses: [],
       all?: false,
       harness_param: nil,
       page: 1,
       filter: :all,
       result: nil,
       error: nil
     )}
  end

  @impl true
  def handle_params(
        params,
        _uri,
        %{assigns: %{current_scope: %{} = scope, project: project}} = socket
      ) do
    page = parse_page(params["page"])
    filter = parse_filter(params["filter"])
    all? = params["harness"] == "all"
    scope = if all?, do: WorkingCopies.viewing(scope), else: scope_for(scope, params["harness"])
    copies = if all?, do: :all, else: :one

    result =
      Problems.list_problems_paginated(scope,
        page: page,
        per_page: @per_page,
        filter: filter,
        working_copy: copies
      )

    harnesses = WorkingCopies.list_harnesses(scope)

    {:noreply,
     assign(socket,
       current_scope: scope,
       all?: all?,
       # Carried on every link, so filtering or paging keeps the copy picked.
       harness_param: if(all?, do: "all", else: params["harness"]),
       harnesses: harnesses,
       copy_names: Map.new(harnesses, &{&1.id, WorkingCopies.display_name(&1)}),
       copy_counts: if(all?, do: Problems.counts_by_working_copy(scope), else: []),
       file_counts: if(all?, do: [], else: Problems.top_files(scope, @top_files)),
       copy_name: copy_name(harnesses, scope.active_working_copy_id),
       page: page,
       filter: filter,
       result: result,
       page_title: "#{project.name} — Problems",
       error: nil
     )}
  end

  # A bar in the per-copy chart picks that copy, as the picker does.
  @impl true
  def handle_event("pick_copy", %{"id" => id}, socket),
    do:
      {:noreply,
       push_patch(socket,
         to:
           problems_path(socket.assigns.project.id,
             page: 1,
             filter: socket.assigns.filter,
             harness: id
           )
       )}

  def handle_event("clear", _params, %{assigns: %{current_scope: scope, filter: filter}} = socket) do
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
     |> assign(
       page: 1,
       result: result,
       copy_counts: if(socket.assigns.all?, do: Problems.counts_by_working_copy(scope), else: []),
       file_counts: if(socket.assigns.all?, do: [], else: Problems.top_files(scope, @top_files))
     )
     |> put_flash(:info, "Cleared #{count} problem(s) from #{label}.")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      project={@project}
      projects={@projects}
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

        <%!-- Across every copy, which holds what; in one copy, where it sits.
      A bar in the first picks its copy, which turns the page into the second. --%>
        <div class="mb-6" data-test="problem-charts">
          <ProblemCharts.by_copy
            :if={@all?}
            counts={@copy_counts}
            harnesses={@harnesses}
            pick_event="pick_copy"
          />
          <ProblemCharts.by_file :if={!@all?} counts={@file_counts} copy_name={@copy_name} />
        </div>

        <.harness_picker
          harnesses={@harnesses}
          active_id={if @all?, do: "all", else: @current_scope.active_working_copy_id}
          path_fun={&problems_path(@project.id, page: 1, filter: @filter, harness: &1)}
          all_path={problems_path(@project.id, page: 1, filter: @filter, harness: "all")}
        />

        <div class="flex flex-wrap items-center gap-2 mb-4" data-test="problems-filters">
          <.link
            patch={problems_path(@project.id, page: 1, filter: :all, harness: @harness_param)}
            data-test="filter-all"
            class={"btn btn-sm " <> if(@filter == :all, do: "btn-primary", else: "btn-ghost")}
          >
            All ({@result.unfiltered_count})
          </.link>
          <.link
            :for={source <- sources()}
            patch={problems_path(@project.id, page: 1, filter: source, harness: @harness_param)}
            data-test={"filter-" <> source}
            class={"btn btn-sm " <> if(@filter == source, do: "btn-primary", else: "btn-ghost")}
          >
            {source} ({Map.get(@result.counts_by_source, source, 0)})
          </.link>

          <button
            :if={@result.problems != [] and not @all?}
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
                <th :if={@all?}>Copy</th>
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
                <td :if={@all?} data-test="problem-copy" class="text-xs">
                  {Map.get(@copy_names, problem.working_copy_id, "—")}
                </td>
                <td data-test="problem-source" class="font-mono text-xs">{problem.source}</td>
                <td data-test="problem-file" class="font-mono text-xs">{problem.file_path || "—"}</td>
                <td class="font-mono text-xs">{problem.line || ""}</td>
                <%!-- The full message rides on the cell's title, so truncating
                    the visible line does not throw the evidence away. On the
                    cell rather than the inner div so the whole cell is the
                    hover target. --%>
                <td data-test="problem-message" class="text-sm" title={problem.message}>
                  <div data-test="problem-message-line" class="max-w-md truncate">
                    {summary_line(problem.message)}
                  </div>
                </td>
                <td class="text-xs opacity-70">{problem.category || ""}</td>
              </tr>
              <tr :if={@result.problems == []}>
                <td
                  colspan={if @all?, do: 7, else: 6}
                  class="text-center opacity-60 py-8"
                  data-test="problems-empty"
                >
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
              patch={
                problems_path(@project.id,
                  page: @result.page - 1,
                  filter: @filter,
                  harness: @harness_param
                )
              }
              data-test="prev-page"
              class="join-item btn btn-sm"
            >
              ← Prev
            </.link>
            <.link
              :if={@result.page < @result.total_pages}
              patch={
                problems_path(@project.id,
                  page: @result.page + 1,
                  filter: @filter,
                  harness: @harness_param
                )
              }
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

  # One line of a message that is sometimes a whole failure.
  #
  # A row is one problem, and the table is for finding the one you want. Most
  # messages are short — 360 of 724 fit in 80 characters — but a spex failure
  # carries its stack trace, and 15 run past 400 characters with the longest at
  # 4,393 and 28 containing newlines. Rendered whole, one of those is taller
  # than the rest of the table.
  #
  # The first line is the part that identifies it: for a spex that is the
  # criterion and what it was checking, and everything after is the trace. Cut
  # to a line and capped, with the whole message on the title attribute and
  # still reachable in full from `list_problems`.
  @message_cap 140

  defp summary_line(nil), do: ""

  defp summary_line(message) do
    message
    |> String.split("\n", parts: 2)
    |> hd()
    |> String.trim()
    |> case do
      "" -> message |> String.replace(~r/\s+/, " ") |> String.trim() |> cap()
      line -> cap(line)
    end
  end

  defp cap(text) when byte_size(text) > @message_cap,
    do: String.slice(text, 0, @message_cap) <> "…"

  defp cap(text), do: text

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

  defp copy_name(harnesses, id) do
    case Enum.find(harnesses, &(&1.id == id)) do
      nil -> "this copy"
      harness -> WorkingCopies.display_name(harness)
    end
  end

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
    harness = Keyword.get(opts, :harness)

    base = "/app/projects/#{slug}/problems"

    params = []
    params = if page > 1, do: [{"page", page} | params], else: params
    params = if filter != :all, do: [{"filter", filter} | params], else: params
    params = if harness, do: [{"harness", harness} | params], else: params

    case params do
      [] -> base
      _ -> base <> "?" <> URI.encode_query(params)
    end
  end
end
