defmodule CodeMySpecWeb.PromotionTimingLive do
  @moduledoc "Promotion timing detail and recent outcome summaries."
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.PromotionQueue.Timings
  alias CodeMySpecWeb.PromotionTiming.Counts
  alias CodeMySpecWeb.PromotionTiming.DailyChart
  alias CodeMySpecWeb.PromotionTiming.PerPromotionChart
  alias CodeMySpecWeb.PromotionTiming.StageTable

  @impl true
  def mount(params, _session, socket) do
    project = socket.assigns.project

    if project.id != params["project_id"] do
      {:ok,
       socket |> put_flash(:error, "Project not found") |> push_navigate(to: ~p"/app/projects")}
    else
      {:ok,
       assign(socket,
         page_title: "Promotion timing",
         window: "24h",
         timing: nil,
         summary: nil,
         timings: [],
         zoom: %{start: 0, end: 100}
       )}
    end
  end

  @impl true
  def handle_params(%{"entry_id" => entry_id}, _uri, socket) do
    {:noreply, assign(socket, timing: Timings.get(socket.assigns.project.id, entry_id))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, load_summary(socket)}
  end

  @impl true
  def handle_event("window", %{"window" => window}, socket) when window in ["24h", "7d"] do
    {:noreply, socket |> assign(window: window, zoom: %{start: 0, end: 100}) |> load_summary()}
  end

  def handle_event("promotion-zoom", %{"start" => start, "end" => finish}, socket)
      when is_number(start) and is_number(finish) do
    start = start |> max(0) |> min(100)
    finish = finish |> max(start) |> min(100)
    {:noreply, assign(socket, zoom: %{start: start, end: finish})}
  end

  defp load_summary(socket) do
    timings = Timings.list(socket.assigns.project.id, socket.assigns.window)
    assign(socket, timings: timings, summary: Timings.summarize(timings, socket.assigns.window))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={@project}
      projects={assigns[:projects] || []}
    >
      <div class="space-y-6">
        <h1 class="text-2xl font-semibold">Promotion timing</h1>
        <%= if @timing do %>
          <p>Promotion {@timing.id} · {@timing.outcome}</p>
          <div data-test="promotion-total" data-duration-seconds={@timing.total_seconds}>
            Total: {format_seconds(@timing.total_seconds)}
          </div>
          <StageTable.detail timing={@timing} />
        <% else %>
          <%= if @summary do %>
            <div data-test="promotion-window" data-window={@window} class="flex gap-2">
              <button
                type="button"
                phx-click="window"
                phx-value-window="24h"
                data-test="promotion-window-24h"
                class="btn btn-sm"
              >Last 24 hours</button>
              <button
                type="button"
                phx-click="window"
                phx-value-window="7d"
                data-test="promotion-window-7d"
                class="btn btn-sm"
              >Last seven days</button>
            </div>
            <p :if={@summary["empty"]} data-test="promotion-timing-empty">
              No promotions ran in this window.
            </p>
            <p
              data-test="promotion-miss-count"
              data-window={@window}
              data-count={@summary["miss_count"]}
            >
              Misses: {@summary["miss_count"]}
            </p>
            <section :for={timing <- @timings} class="space-y-2">
              <% selection = timing.selection %>
              <p
                :if={selection["mode"]}
                data-test="promotion-selection"
                data-mode={selection["mode"]}
              >
                Promotion {timing.id}: {selection["mode"]} selection
              </p>
              <p
                :if={selection["reason"]}
                data-test="promotion-selection-reason"
              >
                {selection["reason"]}
              </p>
              <p
                :if={selection["suite_size"] && selection["suite_size"] > 0}
                data-test="promotion-selected-share"
                data-promotion-id={timing.id}
                data-percent={
                  100 * length(selection["selected_tests"] || []) / selection["suite_size"]
                }
              >
                Selected {length(selection["selected_tests"] || [])} of {selection["suite_size"]} tests
              </p>
              <ul>
                <li
                  :for={file <- selection["selected_tests"] || []}
                  data-test="promotion-selected-test"
                  data-file={file}
                >
                  {file}
                </li>
                <li
                  :for={file <- selection["failed_tests"] || []}
                  data-test="promotion-failed-test"
                  data-file={file}
                >
                  {file}
                </li>
                <li
                  :for={miss <- selection["misses"] || []}
                  data-test="promotion-miss"
                  data-file={miss["file"]}
                >
                  {miss["file"]}: {Enum.join(miss["changed_files"] || [], ", ")}
                </li>
                <li
                  :for={file <- selection["flakes"] || []}
                  data-test="promotion-flake"
                  data-file={file}
                >
                  {file}
                </li>
              </ul>
            </section>
            <div :if={!@summary["empty"]} class="grid gap-6">
              <DailyChart.chart timings={@timings} zoom={@zoom} />
              <PerPromotionChart.chart timings={@timings} zoom={@zoom} />
            </div>
            <section
              :for={outcome <- ~w(landed ejected)}
              data-test={"promotion-outcome-#{outcome}"}
              data-count={@summary["outcomes"][outcome]["count"]}
              class="space-y-3"
            >
              <Counts.summary outcome={outcome} figures={@summary["outcomes"][outcome]} />
              <StageTable.summary outcome={outcome} stages={@summary["outcomes"][outcome]["stages"]} />
            </section>
            <section :for={source <- ~w(exunit spex)} class="space-y-3">
              <h2 class="text-xl font-semibold">Slowest {String.capitalize(source)} tests</h2>
              <ol data-test={"promotion-slowest-tests-#{source}"} class="space-y-1">
                <li
                  :for={item <- @summary["slowest_tests"][source]}
                  data-file={item["file"]}
                  data-duration-seconds={item["duration_seconds"]}
                >
                  {item["name"]} ({item["file"]}): {format_seconds(item["duration_seconds"])}
                </li>
              </ol>
              <h2 class="text-xl font-semibold">Slowest {String.capitalize(source)} test files</h2>
              <ol data-test={"promotion-slowest-files-#{source}"} class="space-y-1">
                <li
                  :for={item <- @summary["slowest_files"][source]}
                  data-file={item["file"]}
                  data-duration-seconds={item["duration_seconds"]}
                >
                  {item["file"]}: {format_seconds(item["duration_seconds"])}
                </li>
              </ol>
            </section>
          <% else %>
            <p>Promotion not found.</p>
          <% end %>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  defp format_seconds(seconds), do: "#{seconds}s"
end
