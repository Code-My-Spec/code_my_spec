defmodule CodeMySpecWeb.ArchitectureComponents do
  @moduledoc """
  The boundary graph from `BoundaryGraph.build/1`: its summary, the graph
  itself on the `SigmaGraph` hook, and a modal holding both.
  """
  use CodeMySpecWeb, :html

  @doc "The claims the graph makes, stated so they can be checked against it."
  attr :summary, :map, required: true

  def summary(assigns) do
    ~H"""
    <div data-test="boundary-summary" class="text-sm text-base-content/70 space-y-1">
      <p :if={!@summary.declarations_recorded} class="text-warning">
        No `use Boundary` declarations recorded yet — they arrive with the next full scan.
      </p>
      <p>
        <span data-test="boundary-count">{@summary.boundaries} boundaries</span>, <span data-test="boundary-edges">{@summary.edges} dependencies between them</span>,
        <span data-test="boundary-depth">{@summary.depth} deep</span>
        <span :if={@summary.unowned_modules > 0}>
          · {@summary.unowned_modules} modules under no boundary
        </span>
      </p>
      <p :if={@summary.longest_chain != []} data-test="boundary-longest-chain" class="break-words">
        Longest chain: {Enum.join(@summary.longest_chain, " → ")}
      </p>
      <p :if={@summary.cycles == []} data-test="boundary-cycles">No cycles.</p>
      <div :if={@summary.cycles != []} data-test="boundary-cycles" class="text-error">
        {length(@summary.cycles)} cycle(s), drawn in red:
        <ul class="list-disc ml-5">
          <li :for={cycle <- @summary.cycles}>{Enum.join(cycle, " ↔ ")}</li>
        </ul>
      </div>
    </div>
    """
  end

  @doc "The graph, with a home for its copy-debug button at `<id>-debug`."
  attr :id, :string, required: true
  attr :graph, :map, required: true
  attr :class, :any, default: "h-[80vh]"

  def graph(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook="SigmaGraph"
      data-graph={Jason.encode!(Map.delete(@graph, :summary))}
      phx-update="ignore"
      class={[
        "relative w-full overflow-hidden rounded-box border border-base-300 bg-base-200",
        @class
      ]}
    >
    </div>
    <div id={"#{@id}-debug"} phx-update="ignore"></div>
    """
  end

  @doc "The summary over the graph, with the way to the full page. Pushes `on_close`."
  attr :graph, :map, required: true
  attr :href, :string, required: true
  attr :on_close, :string, required: true
  attr :target, :any, default: nil

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="architecture-modal"
      phx-window-keydown={@on_close}
      phx-key="Escape"
      phx-target={@target}
    >
      <div class="modal-box w-11/12 max-w-5xl space-y-3">
        <button
          type="button"
          phx-click={@on_close}
          phx-target={@target}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <h2 class="pr-8 text-lg font-semibold">Architecture</h2>
        <.summary summary={@graph.summary} />
        <.graph id="architecture-modal-graph" graph={@graph} class="h-[55dvh]" />
        <div class="flex justify-end">
          <.link navigate={@href} data-test="architecture-modal-open" class="btn btn-sm btn-ghost">
            Open architecture <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click={@on_close}
        phx-target={@target}
        aria-label="Close"
      ></button>
    </div>
    """
  end
end
