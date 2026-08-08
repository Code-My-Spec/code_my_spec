defmodule CodeMySpecWeb.Tasks.TaskQueueLive do
  @moduledoc """
  Story 811 — the engineer's at-a-glance view of the agent's task
  queue: the requirement the agent is on right now and the ordered
  list of what's next, both rendered on a single screen.

  Backed directly by `RequirementGraph.next_actionable/1`. The head
  of the actionable list is the active task; the tail (up to the
  configured cap) is the upcoming list. When everything is
  satisfied — empty actionable list — the page renders the explicit
  empty-state region so it never looks like a render error.

  Live updates: subscribes to file change events on this project so
  every sync (manual or watcher-driven) re-renders the queue
  without a refresh.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.ProjectSync.Sync, as: ProjectSync
  alias CodeMySpec.Requirements.RequirementGraph
  alias CodeMySpec.Users.Scope

  # Per story 811 question resolution: top 25 in the upcoming list.
  @upcoming_cap 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :next_task,
       page_title: "Tasks",
       active: nil,
       upcoming: [],
       error: nil
     )}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{scope: %{} = scope, project: project}} = socket) do
    if connected?(socket), do: subscribe_to_state_changes(scope)

    {:noreply,
     socket
     |> assign(
       page_title: "#{project.name} — Task Queue",
       error: nil
     )
     |> recompute()}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Requirement satisfaction is computed fresh from Components +
  # Files + Problems on every recompute. The components context
  # broadcasts on every upsert (file sync routes through there),
  # which fans out enough of the relevant state changes to keep
  # the queue live without each tuple needing its own topic.
  @impl true
  def handle_info({_action, _struct}, socket) do
    {:noreply, recompute(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp subscribe_to_state_changes(%Scope{active_account_id: account_id} = scope)
       when is_binary(account_id) do
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:components")
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:issues")

    # File-only changes (project_setup satisfaction, spec file edits, etc.)
    # don't broadcast on the components or issues topics. ProjectSync.Sync
    # broadcasts on `"project:<id>:watcher"` whenever the file watcher
    # syncs a file change, which is the broadest signal for "the
    # requirement graph might have shifted." Subscribing here keeps the
    # queue live for file-only events too.
    ProjectSync.subscribe(scope)
  end

  defp subscribe_to_state_changes(_scope), do: :ok

  defp recompute(%{assigns: %{scope: nil}} = socket), do: socket

  defp recompute(%{assigns: %{scope: scope}} = socket) do
    # From the published snapshot when it still matches current inputs. This
    # re-renders on every state change, and recomputing the graph each time is
    # node and edge computation the project already paid for — 4.4 seconds of
    # it on a 3200-component project. A queue is a display; it can be a moment
    # behind on the delegate checks the fingerprint cannot see.
    {_graph, actionable, _computed_at} = RequirementGraph.cached_graph_with_actionable(scope)

    {active, upcoming} =
      case actionable do
        [] -> {nil, []}
        [head | rest] -> {head, Enum.take(rest, @upcoming_cap)}
      end

    assign(socket, active: active, upcoming: upcoming)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} role="alert" class="alert alert-error">
      <span>{@error}</span>
    </div>

    <div :if={!@error}>
      <div class="mb-6">
        <h1 class="text-3xl font-bold">Task Queue</h1>
        <p class="text-base-content/60 mt-1">
          What the agent's working on now and what's next.
          Updates live as the agent advances.
        </p>
      </div>

      <%= if @active do %>
        <section
          data-test="active-task"
          data-requirement={requirement_name(@active)}
          data-entity-id={requirement_entity_id(@active)}
          class="mb-8 bg-base-200 border border-primary rounded-box p-6"
        >
          <div class="text-xs uppercase tracking-wider text-primary mb-2">
            Active task
          </div>
          <div class="text-xl font-semibold">{requirement_label(@active)}</div>
          <div :if={@active.description} class="text-base-content/70 mt-2">
            {@active.description}
          </div>
          <div class="text-xs text-base-content/50 mt-3 font-mono">
            {requirement_name(@active)} · {requirement_entity_kind(@active)} · {requirement_entity_id(
              @active
            )}
          </div>
        </section>

        <section
          data-test="upcoming-tasks"
          class="bg-base-100 border border-base-300 rounded-box p-4"
        >
          <div class="text-xs uppercase tracking-wider text-base-content/60 mb-3">
            Upcoming ({length(@upcoming)})
          </div>

          <%= if @upcoming == [] do %>
            <div class="text-base-content/50 italic">
              Nothing else queued.
            </div>
          <% else %>
            <ul class="space-y-2">
              <li
                :for={req <- @upcoming}
                data-test="upcoming-task-item"
                data-requirement={requirement_name(req)}
                data-entity-id={requirement_entity_id(req)}
                class="flex items-baseline gap-3 border-l-2 border-base-300 pl-3 py-1"
              >
                <span class="text-xs text-base-content/40 font-mono shrink-0">
                  {requirement_entity_kind(req)}
                </span>
                <span class="flex-1">{requirement_label(req)}</span>
                <span class="text-xs font-mono text-base-content/50">
                  {requirement_name(req)}
                </span>
              </li>
            </ul>
          <% end %>
        </section>
      <% else %>
        <section
          data-test="empty-queue"
          class="bg-base-200 border border-base-300 rounded-box p-12 text-center"
        >
          <div class="text-2xl font-semibold mb-2">Nothing to do</div>
          <p class="text-base-content/60">
            Every actionable requirement is satisfied.
            The agent has no queued work.
          </p>
        </section>
      <% end %>
    </div>
    """
  end

  # -- Render helpers -------------------------------------------------------

  defp requirement_name(%{name: name}), do: name
  defp requirement_entity_id(%{entity_id: id}), do: to_string(id)
  defp requirement_entity_kind(%{entity_type: t}), do: t

  defp requirement_label(%{entity_name: entity_name, name: name}) do
    case entity_name do
      nil -> name
      "" -> name
      label -> "#{label} — #{name}"
    end
  end
end
