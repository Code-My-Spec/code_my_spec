defmodule CodeMySpecWeb.WorkingCopyLive.Components.StoryGraph do
  @moduledoc "Story requirement cards and their selected details."
  use CodeMySpecWeb, :html

  attr(:title, :string, default: "Story requirements")
  attr(:issue_bag, :boolean, default: false)
  attr(:flow, :any, default: nil)
  attr(:stories, :list, required: true)
  attr(:story_id, :any, default: nil)
  attr(:selected, :any, default: nil)
  attr(:error, :string, default: nil)

  def graph(assigns) do
    ~H"""
    <section class="space-y-3" data-test="story-requirements">
      <div class="flex flex-wrap items-center justify-between gap-3">
        <h2 class="text-lg font-semibold">{@title}</h2>
        <button
          :if={@flow && map_size(@flow.nodes) > 0}
          phx-click="lf:request_layout"
          class="btn btn-sm btn-ghost"
        >
          Arrange
        </button>
      </div>
      <p :for={story <- if(@issue_bag, do: [], else: @stories)} class="font-medium">
        {story.number} · {story.title}
      </p>
      <p :if={@stories == [] and not @issue_bag} class="text-sm opacity-60">
        No story assigned to this working copy.
      </p>
      <p :if={@error} role="alert" class="text-error">{@error}</p>
      <p :if={@story_id && is_nil(@flow) && is_nil(@error)} class="text-sm opacity-60">
        Loading requirements…
      </p>
      <p :if={@flow && map_size(@flow.nodes) == 0} class="text-sm opacity-60">
        No published requirements for this story at this working copy.
      </p>
      <div :if={@flow && map_size(@flow.nodes) > 0}>
        <.canvas
          flow={@flow}
          id="story-requirements-flow"
          class="h-[calc(100dvh-260px)] min-h-[420px]"
        />
      </div>
    </section>
    """
  end

  attr(:flow, :any, required: true)
  attr(:id, :string, required: true)
  attr(:class, :string, default: nil)
  attr(:style, :string, default: nil)

  @doc "The requirement cards and their edges, read-only. Shared with the cockpit's pie modal."
  def canvas(assigns) do
    ~H"""
    <div
      class={["story-requirements overflow-hidden rounded-box border border-base-300", @class]}
      style={@style}
    >
      <.live_component
        module={LiveFlow.Components.Flow}
        id={@id}
        flow={@flow}
        node_types={%{requirement: &requirement/1, context: &context/1}}
        opts={%{controls: true, nodes_draggable: false, nodes_connectable: false}}
      />
    </div>
    """
  end

  attr(:selected, :any, default: nil)

  def selection(assigns) do
    ~H"""
    <div
      :if={@selected}
      class="mt-3 rounded-box border border-base-300 p-4"
      data-test="requirement-details"
    >
      <div class="flex justify-between gap-3">
        <h3 class="font-semibold">{@selected.data.label}</h3>
        <span class="badge badge-outline">{@selected.data.status}</span>
      </div>
      <%= if @selected.type == :context do %>
        <p class="mt-2 text-sm opacity-70">Only requirements related to this story.</p>
        <div
          class="mt-3 max-h-96 overflow-y-auto divide-y divide-base-300"
          data-test="context-requirements"
        >
          <details :for={item <- @selected.data.requirements} class="py-2">
            <summary class="cursor-pointer text-sm">
              <span class={["badge badge-sm mr-2", status_class(item.status)]}>
                {item.status}
              </span>
              {item.requirement.entity_name} · {item.label}
            </summary>
            <.requirement_details data={item} />
          </details>
        </div>
      <% else %>
        <.requirement_details data={@selected.data} />
      <% end %>
    </div>
    """
  end

  attr(:node, :any, required: true)

  def requirement(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_requirement"
      phx-value-id={@node.id}
      class="relative block w-full p-3 text-left"
      aria-label={@node.data.label}
      style={next_style(@node.data)}
      data-next-agent-ids={Enum.map_join(@node.data.next_agents, " ", & &1.id)}
    >
      <span
        :if={@node.data.warnings != []}
        class="absolute right-1 top-1 badge badge-warning badge-xs"
        title="Pending question or tap-out"
        aria-label="Pending question or tap-out"
        data-test="requirement-warning"
      >
        !
      </span>
      <span class="block font-semibold leading-snug">{@node.data.label}</span>
      <span
        :if={@node.data.requirement.entity_type != "story" or @node.data.boundary}
        class="mt-1 block text-xs break-words opacity-65"
      >
        {@node.data.requirement.entity_name}
      </span>
      <span class={["mt-2 badge badge-sm", status_class(@node.data.status)]}>
        {@node.data.status}
      </span>
      <span :if={@node.data.boundary} class="ml-1 text-xs opacity-60">External prerequisite</span>
    </button>
    """
  end

  attr(:node, :any, required: true)

  def context(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="select_requirement"
      phx-value-id={@node.id}
      class="relative block w-full p-3 text-left"
      aria-label={@node.data.label}
      style={next_style(@node.data)}
      data-next-agent-ids={Enum.map_join(@node.data.next_agents, " ", & &1.id)}
    >
      <span
        :if={@node.data.warnings != []}
        class="absolute right-1 top-1 badge badge-warning badge-xs"
        title="Pending question or tap-out"
        aria-label="Pending question or tap-out"
        data-test="requirement-warning"
      >
        !
      </span>
      <span class="block font-semibold leading-snug break-words">{@node.data.label}</span>
      <span class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs">
        <span class="text-success">{Map.get(@node.data.counts, "Satisfied", 0)} satisfied</span>
        <span class="text-info">{Map.get(@node.data.counts, "Actionable", 0)} actionable</span>
        <span class="text-warning">{Map.get(@node.data.counts, "Blocked", 0)} blocked</span>
      </span>
    </button>
    """
  end

  attr(:data, :map, required: true)

  defp requirement_details(assigns) do
    ~H"""
    <p class="mt-2 text-sm">{@data.requirement.description}</p>
    <p class="mt-2 text-sm opacity-70">{@data.requirement.entity_name}</p>
    <p :if={@data.boundary} class="mt-2 text-sm">
      Outside this story; shown because it is a prerequisite.
    </p>
    <pre :if={@data.requirement.details != %{}} class="mt-3 whitespace-pre-wrap break-words text-xs">{Jason.encode!(@data.requirement.details, pretty: true)}</pre>
    """
  end

  defp next_style(data) do
    data.next_agents
    |> Enum.with_index(1)
    |> Enum.map_join(", ", fn {agent, index} ->
      "inset 0 0 0 #{index * 3}px #{CodeMySpecWeb.WorkingCopyLive.Components.Agent.color(agent.id)}"
    end)
    |> then(fn
      "" -> nil
      shadows -> "box-shadow: #{shadows}; border-radius: 8px"
    end)
  end

  defp status_class("Satisfied"), do: "badge-success"
  defp status_class("Actionable"), do: "badge-info"
  defp status_class(_), do: "badge-warning"
end
