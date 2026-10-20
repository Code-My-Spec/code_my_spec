defmodule CodeMySpecWeb.RequirementGraphComponents do
  @moduledoc """
  The requirements graph over whatever page is open, and the detail of the
  node selected in it — what the retired requirement page showed: what it is,
  whether it holds and why, what satisfies it, what it waits on and what it
  unblocks.

  The page that renders `modal/1` holds the state: the projected graph, the
  requirements by graph key (`GraphProjector.key/1`), and the selected key. A
  node clicked in the graph pushes `select_node` with its key to `target`.
  """
  use CodeMySpecWeb, :html

  import CodeMySpecWeb.Markdown, only: [md_html: 1]

  alias CodeMySpec.Agents
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.GraphProjector
  alias CodeMySpec.Stories
  alias CodeMySpec.Utils.MapAccess

  @doc """
  `graph` is `:loading`, `:error`, or `%{data: projected, requirements: %{key => node}}`.
  """
  attr :graph, :any, required: true
  attr :selected, :string, default: nil
  attr :detail, :map, default: %{}
  attr :href, :string, required: true
  attr :target, :any, required: true, doc: "where close_graph and select_node go"

  attr :target_selector, :string,
    required: true,
    doc: "the same target, as a selector the graph hook can push to"

  def modal(assigns) do
    ~H"""
    <div
      class="modal modal-open"
      role="dialog"
      aria-modal="true"
      data-test="graph-modal"
      phx-window-keydown="close_graph"
      phx-key="Escape"
      phx-target={@target}
    >
      <div class="modal-box w-11/12 max-w-7xl space-y-3">
        <button
          type="button"
          phx-click="close_graph"
          phx-target={@target}
          class="btn btn-ghost btn-sm btn-circle absolute right-2 top-2"
          aria-label="Close"
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
        <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1 pr-8">
          <h2 class="text-lg font-semibold">Requirements graph</h2>
          <.legend />
        </div>
        <p :if={@graph == :loading} class="text-sm opacity-60">Computing the graph…</p>
        <p :if={@graph == :error} role="alert" class="text-sm text-error">
          The graph could not be computed. Try the full page.
        </p>
        <div :if={is_map(@graph)} class="grid gap-3 lg:grid-cols-[minmax(0,1fr)_20rem]">
          <div
            id="timeline-graph"
            phx-hook="SigmaGraph"
            phx-update="ignore"
            data-graph={Jason.encode!(@graph.data)}
            data-focus={@selected}
            data-select-target={@target_selector}
            class="rounded-box border border-base-300 bg-base-200"
            style="position: relative; overflow: hidden; width: 100%; height: 65vh;"
          >
          </div>
          <.node_detail
            node={@selected && @graph.requirements[@selected]}
            edges={@graph.data.edges}
            requirements={@graph.requirements}
            extra={@detail}
            target={@target}
          />
        </div>
        <div class="flex justify-end">
          <.link navigate={@href} data-test="graph-modal-open" class="btn btn-sm btn-ghost">
            Full page <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          </.link>
        </div>
      </div>
      <button
        type="button"
        class="modal-backdrop"
        phx-click="close_graph"
        phx-target={@target}
        aria-label="Close"
      ></button>
    </div>
    """
  end

  @doc """
  What the detail pane shows beyond the node itself, read when a node is
  picked: the page that owns it, the directive `get_next_requirement` gives
  for it, and the agents with an active task on it.
  """
  def detail(scope, node) do
    %{
      href: owner_path(scope, node),
      directive: Requirements.node_directive(scope, node),
      agents: working_on(scope, node)
    }
  end

  defp working_on(scope, node) do
    Enum.filter(Agents.list_agents(scope), fn agent ->
      Agents.on_duty?(agent) and
        Enum.any?(agent.tasks || [], &(&1.status == :active and Requirements.task_on?(node, &1)))
    end)
  end

  defp owner_path(scope, %{entity_type: "story", entity_id: id}) do
    case Stories.get_story(scope, id) do
      nil -> nil
      story -> ~p"/app/projects/#{scope.active_project_id}/stories/#{story.number}"
    end
  end

  defp owner_path(scope, %{entity_type: "issue", entity_id: id}),
    do: ~p"/app/projects/#{scope.active_project_id}/issues/#{id}"

  defp owner_path(_scope, _node), do: nil

  @doc """
  What the node colours mean — the same three the canvas paints from the
  theme by each node's status (`statusColor` in `sigma_graph.js`).
  """
  def legend(assigns) do
    ~H"""
    <div data-test="graph-legend" class="flex flex-wrap gap-4 text-xs">
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-success"></span> Satisfied
      </span>
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-warning"></span> Ready to work on
      </span>
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-base-content/35"></span> Waiting
      </span>
      <span class="flex items-center gap-1.5">
        <span class="size-2.5 rounded-full bg-base-content/15"></span> Not in the plan
      </span>
    </div>
    """
  end

  @doc "One requirement in the graph, or a prompt to pick one."
  attr :node, :any, required: true
  attr :extra, :map, default: %{}, doc: "from `detail/2`"
  attr :edges, :list, required: true
  attr :requirements, :map, required: true
  attr :target, :any, required: true

  def node_detail(%{node: nil} = assigns) do
    ~H"""
    <aside data-test="node-detail" class="text-sm opacity-60">
      Click a node to see what it is and what it waits on.
    </aside>
    """
  end

  def node_detail(assigns) do
    key = GraphProjector.key(assigns.node)

    assigns =
      assign(assigns,
        basis: basis(assigns.node),
        waits_on: linked(assigns.edges, assigns.requirements, key, :target, :source),
        unblocks: linked(assigns.edges, assigns.requirements, key, :source, :target)
      )

    ~H"""
    <aside
      data-test="node-detail"
      data-node={@node.name}
      class="max-h-[65vh] space-y-3 overflow-y-auto text-sm"
    >
      <header>
        <p :if={@node.entity_name} class="text-xs opacity-60">
          {@node.entity_type} ·
          <.link :if={@extra[:href]} navigate={@extra[:href]} data-test="node-owner" class="link">
            {@node.entity_name}
          </.link>
          <span :if={!@extra[:href]}>{@node.entity_name}</span>
        </p>
        <h3 class="break-all font-mono font-semibold">{@node.name}</h3>
        <p class="mt-1 opacity-80">{@node.description}</p>
        <span class={[
          "badge badge-sm mt-2",
          if(@node.satisfied, do: "badge-success", else: "badge-ghost")
        ]}>
          {if @node.satisfied, do: "satisfied", else: "not satisfied"}
        </span>
        <p :if={@basis} data-test="node-basis" class="mt-1 text-xs opacity-70">{@basis}</p>
      </header>

      <p :if={@node.satisfied_by} class="text-xs opacity-60">
        Satisfied by <code class="font-mono">{short(@node.satisfied_by)}</code>
      </p>

      <section :if={@extra[:agents] not in [nil, []]} data-test="node-agents">
        <h4 class="mb-1 text-xs font-semibold opacity-60">Being worked on by</h4>
        <ul class="flex flex-wrap gap-1.5">
          <li :for={agent <- @extra.agents} class="badge badge-sm badge-primary badge-soft">
            {agent.role} · {String.slice(agent.id, 0, 8)}
          </li>
        </ul>
      </section>

      <.links :if={@waits_on != []} title="Waits on" links={@waits_on} target={@target} />
      <.links :if={@unblocks != []} title="Unblocks" links={@unblocks} target={@target} />

      <details :if={@extra[:directive] not in [nil, ""]} data-test="node-directive" open>
        <summary class="cursor-pointer text-xs opacity-60">What an agent is told</summary>
        <div class="prose prose-sm mt-1 max-w-none rounded-box bg-base-200 p-2 text-xs">
          {md_html(@extra.directive)}
        </div>
      </details>

      <details :if={(@node.details || %{}) != %{}}>
        <summary class="cursor-pointer text-xs opacity-60">Details</summary>
        <pre class="mt-1 overflow-x-auto rounded-box bg-base-200 p-2 font-mono text-[11px]">{Jason.encode!(@node.details, pretty: true)}</pre>
      </details>
    </aside>
    """
  end

  attr :title, :string, required: true
  attr :links, :list, required: true
  attr :target, :any, required: true

  defp links(assigns) do
    ~H"""
    <section>
      <h4 class="mb-1 text-xs font-semibold opacity-60">{@title}</h4>
      <ul class="flex flex-wrap gap-1.5">
        <li :for={link <- @links}>
          <button
            type="button"
            phx-click="select_node"
            phx-value-key={link.key}
            phx-target={@target}
            class="inline-flex items-center gap-1 rounded-full border border-base-300 px-2 py-0.5 font-mono text-xs hover:bg-base-200"
          >
            <span class={[
              "size-1.5 rounded-full",
              if(link.satisfied, do: "bg-success", else: "bg-base-content/30")
            ]}></span>
            {link.label}
          </button>
        </li>
      </ul>
    </section>
    """
  end

  # The nodes on the other end of this one's edges: what it waits on (edges
  # into it) or what it unblocks (edges out of it).
  defp linked(edges, requirements, key, this_end, other_end) do
    for edge <- edges,
        Map.get(edge, this_end) == key,
        other = Map.get(edge, other_end),
        node = requirements[other] do
      %{key: other, label: label(node), satisfied: node.satisfied}
    end
  end

  defp label(%{entity_type: "project", name: name}), do: name
  defp label(%{entity_name: entity, name: name}) when is_binary(entity), do: "#{entity} · #{name}"
  defp label(%{name: name}), do: name

  defp basis(node) do
    details = node.details || %{}
    MapAccess.get(details, :status) || MapAccess.get(details, :reason)
  end

  defp short(module), do: module |> inspect() |> String.split(".") |> List.last()
end
