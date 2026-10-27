defmodule CodeMySpecWeb.PromotionTimingLive do
  @moduledoc "Promotion timing detail and recent outcome summaries."
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.PromotionQueue.Timings

  @impl true
  def mount(params, _session, socket) do
    project = socket.assigns.project

    if project.id != params["project_id"] do
      {:ok,
       socket |> put_flash(:error, "Project not found") |> push_navigate(to: ~p"/app/projects")}
    else
      {:ok,
       assign(socket, page_title: "Promotion timing", window: "24h", timing: nil, summary: nil)}
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
    {:noreply, socket |> assign(window: window) |> load_summary()}
  end

  defp load_summary(socket) do
    assign(socket, summary: Timings.summary(socket.assigns.project.id, socket.assigns.window))
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
          <div class="space-y-2">
            <div
              :for={stage <- Timings.stages()}
              data-test={"promotion-stage-#{stage}"}
              data-status={stage_status(@timing.stages[stage])}
              data-duration-seconds={@timing.stages[stage].duration_seconds}
              class="flex gap-3"
            >
              <span>{label(stage)}</span>
              <span>{format_stage(@timing.stages[stage])}</span>
            </div>
          </div>
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
            <section
              :for={outcome <- ~w(landed ejected)}
              data-test={"promotion-outcome-#{outcome}"}
              data-count={@summary["outcomes"][outcome]["count"]}
              class="space-y-3"
            >
              <h2 class="text-xl font-semibold">
                {String.capitalize(outcome)}: {@summary["outcomes"][outcome]["count"]}
              </h2>
              <p
                data-test={"promotion-gate-time-#{outcome}"}
                data-duration-seconds={@summary["outcomes"][outcome]["gate_seconds"]}
              >
                Gate time: {format_seconds(@summary["outcomes"][outcome]["gate_seconds"])}
              </p>
              <div
                :for={{stage, figures} <- @summary["outcomes"][outcome]["stages"]}
                data-test={"promotion-summary-#{outcome}-#{stage}"}
                class="flex flex-wrap gap-4"
              >
                <strong>{label(stage)}</strong>
                <span data-stat="median" data-duration-seconds={figures["median_seconds"]}>Median: {format_seconds(
                  figures["median_seconds"]
                )}</span>
                <span data-stat="p90" data-duration-seconds={figures["p90_seconds"]}>P90: {format_seconds(
                  figures["p90_seconds"]
                )}</span>
                <span data-stat="total" data-duration-seconds={figures["total_seconds"]}>Total: {format_seconds(
                  figures["total_seconds"]
                )}</span>
              </div>
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

  defp stage_status(%{status: :not_run}), do: "not-run"
  defp stage_status(%{status: :ran}), do: "ran"

  defp label(stage), do: stage |> String.replace("-", " ") |> String.capitalize()
  defp format_stage(%{status: :not_run}), do: "Not run"
  defp format_stage(%{duration_seconds: seconds}), do: format_seconds(seconds)
  defp format_seconds(seconds), do: "#{seconds}s"
end
