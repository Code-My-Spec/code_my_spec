defmodule CodeMySpecWeb.EpicsLive.Index do
  @moduledoc """
  Project-scoped epic board for the local app.

  Two columns: epics on the left, unfiled stories on the right. Stories drag
  between them; dropping into an epic files the story there and removes it
  from the unfiled column. A story belongs to at most one epic, so every drop
  is a move.

  Sortable pushes `move_story` from the receiving list, so the destination is
  whatever dropzone the story landed in — an epic, or the unfiled column whose
  `data-epic-id` is empty. The server is the source of truth: every drop
  reloads the board, so a rejected move snaps back.

  Epics are organizational. Filing a story does not release it for
  development; the per-epic release button does that as a one-shot bulk edit.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.EpicDispatch
  alias CodeMySpec.Epics
  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Stories
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.EpicsLive.FormComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :epics,
       error: nil,
       page_title: "Epics",
       epics: [],
       unassigned: [],
       epic: nil,
       watching_epics: false
     )}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{scope: %{} = scope}} = socket) do
    {:noreply,
     socket
     |> watch_epics(scope)
     |> load_board(scope)
     |> apply_action(socket.assigns.live_action, params, scope)}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  # Subscribed here rather than at mount, because the topic is keyed on the
  # active project and that arrives with the params. Once per socket: a
  # `handle_params` runs again on every patch, and subscribing each time would
  # redraw the board once per copy of the subscription.
  defp watch_epics(socket, scope) do
    if connected?(socket) and not socket.assigns[:watching_epics] do
      Epics.subscribe(scope)
      assign(socket, :watching_epics, true)
    else
      socket
    end
  end

  defp apply_action(socket, :new, _params, _scope) do
    socket
    |> assign(:page_title, "New Epic")
    |> assign(:epic, %Epic{})
  end

  defp apply_action(socket, :edit, %{"slug" => epic_slug}, scope) do
    case Epics.get_epic_by_slug(scope, epic_slug) do
      nil ->
        socket
        |> put_flash(:error, "Epic not found")
        |> push_patch(to: path(socket, ~p"/app/projects/#{socket.assigns.slug}/epics"))

      epic ->
        socket
        |> assign(:page_title, "Edit Epic")
        |> assign(:epic, epic)
    end
  end

  defp apply_action(socket, _action, _params, _scope) do
    socket
    |> assign(:page_title, "Epics")
    |> assign(:epic, nil)
  end

  @impl true
  # The main agent works while somebody is looking at this page. Every change it
  # makes to an epic arrives here and redraws the board, which is what "watch it
  # take shape" means — without it the screen is a snapshot from whenever it was
  # last loaded.
  #
  # Above the catch-all below, which is where this first went and where it was
  # dead code: `handle_info(_msg, socket)` matches everything, so a clause after
  # it never runs.
  def handle_info({event, _epic}, socket)
      when event in [:epic_created, :epic_updated, :epic_deleted] do
    {:noreply, load_board(socket, socket.assigns.scope)}
  end

  def handle_info({:epic_saved, _epic}, socket) do
    {:noreply, load_board(socket, socket.assigns.scope)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("move_story", %{"story_id" => story_id, "epic_id" => epic_id}, socket) do
    scope = socket.assigns.scope

    with {:ok, story} <- fetch_story(scope, story_id),
         {:ok, epic} <- fetch_epic_by_id(scope, epic_id),
         {:ok, _story} <- Epics.assign_story(scope, story, epic) do
      {:noreply, load_board(socket, scope)}
    else
      {:error, reason} ->
        # Reload either way — the browser has already moved the node, so the
        # board must be re-rendered from server state or the two diverge.
        {:noreply,
         socket
         |> put_flash(:error, "Could not move story: #{inspect(reason)}")
         |> load_board(scope)}
    end
  end

  # Agreeing is the act that starts work. `EpicDispatch.approve/2` refuses
  # anything that was not proposed first, so this cannot become a second route
  # that bypasses the gate.
  def handle_event("approve_epic", %{"id" => id}, socket) do
    case EpicDispatch.approve(socket.assigns.scope, id) do
      {:ok, _epic} ->
        {:noreply, socket |> put_flash(:info, "Building it.") |> load_board(socket.assigns.scope)}

      {:error, :not_proposed} ->
        {:noreply,
         put_flash(socket, :error, "That epic has not been put forward for building yet.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "That epic could not be started.")}
    end
  end

  def handle_event("release_epic", %{"id" => id}, socket) do
    set_epic_readiness(socket, id, true)
  end

  def handle_event("park_epic", %{"id" => id}, socket) do
    set_epic_readiness(socket, id, false)
  end

  def handle_event("toggle_story_ready", %{"id" => id}, socket) do
    scope = socket.assigns.scope

    with {:ok, story} <- fetch_story(scope, id),
         {:ok, _updated} <-
           Stories.update_story(scope, story, %{ready_for_dev: !(story.ready_for_dev == true)}) do
      {:noreply, load_board(socket, scope)}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change readiness: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.scope

    case Epics.get_epic(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Epic not found")}

      epic ->
        case Epics.delete_epic(scope, epic) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Epic deleted — its stories were kept and are now unfiled")
             |> load_board(scope)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not delete: #{inspect(reason)}")}
        end
    end
  end

  defp set_epic_readiness(socket, id, ready?) do
    scope = socket.assigns.scope

    case Epics.get_epic(scope, id) do
      nil -> {:noreply, put_flash(socket, :error, "Epic not found")}
      epic -> update_epic_readiness(socket, scope, epic, ready?)
    end
  end

  defp update_epic_readiness(socket, scope, epic, ready?) do
    case Epics.set_epic_stories_ready(scope, epic, ready?) do
      {:ok, count} ->
        verb = if ready?, do: "released for development", else: "parked"

        {:noreply,
         socket
         |> put_flash(
           :info,
           "#{count} #{noun(count)} in #{epic.name} #{verb}. Stories filed here later are unaffected."
         )
         |> load_board(scope)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update: #{inspect(reason)}")}
    end
  end

  defp fetch_story(scope, id) do
    case Stories.get_story(scope, id) do
      nil -> {:error, :story_not_found}
      story -> {:ok, story}
    end
  end

  # The board's unfiled column carries no epic id, so an empty string means
  # "take this story out of whatever epic it was in".
  defp fetch_epic_by_id(_scope, id) when id in [nil, ""], do: {:ok, nil}

  defp fetch_epic_by_id(scope, id) do
    case Epics.get_epic(scope, id) do
      nil -> {:error, :epic_not_found}
      epic -> {:ok, epic}
    end
  end

  defp project_stories(scope) do
    case Stories.list_project_stories(scope) do
      {:ok, stories} -> stories
      stories when is_list(stories) -> stories
      _ -> []
    end
  end

  defp load_board(socket, scope) do
    stories = project_stories(scope)

    socket
    |> assign(:epics, Epics.list_epics(scope))
    |> assign(
      :unassigned,
      stories |> Enum.filter(&is_nil(&1.epic_id)) |> Enum.sort_by(& &1.title)
    )
    |> assign(:working_copy_names, working_copy_names(scope))
  end

  # One query for every working copy this project has, instead of the
  # `WorkingCopies.fetch/1` per unique id per epic this replaced — each of
  # those was its own `Repo.get` + `Repo.preload(:project)` round trip, run
  # again on every render of a board that can hold a few hundred stories.
  defp working_copy_names(scope) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Map.new(&{&1.id, WorkingCopies.display_name(&1)})
  end

  defp epic_stories(epic) do
    if Ecto.assoc_loaded?(epic.stories),
      do: Enum.sort_by(epic.stories, & &1.title),
      else: []
  end

  defp ready_count(epic), do: Enum.count(epic_stories(epic), &(&1.ready_for_dev == true))

  # How many of this epic's stories are bound to a checkout.
  defp assigned_count(epic) do
    epic |> epic_stories() |> Enum.count(&(&1.working_copy_id != nil))
  end

  # The checkouts its stories are on, named rather than numbered — a uuid tells
  # a reader nothing.
  #
  # Takes the id->name map `load_board/2` built in one query, rather than
  # calling `WorkingCopies.fetch/1` per id here: this runs once per epic on
  # every render, and a fetch-per-call was a `Repo.get` + `Repo.preload` round
  # trip each time — the board's actual slow part on a project with a few
  # hundred stories.
  defp copy_names(epic, names) do
    epic
    |> epic_working_copy_ids()
    |> Enum.map(&copy_name(&1, names))
    |> case do
      [] -> "no checkout"
      [one] -> one
      many -> Enum.join(many, ", ")
    end
  end

  defp copy_name(id, names), do: Map.get(names, id, "a checkout")

  # Which checkout an epic is being built on, read off its stories.
  #
  # Derived rather than stored since 2026-09-05: the epic's own column was never
  # consulted for routing, so it recorded a hand-off nothing performed. The
  # binding is `stories.working_copy_id` now, and this reads it back.
  #
  # Several is a real answer here — two stories of one epic can sit on two
  # checkouts, which the old shape could not express. The page says so rather
  # than picking one and looking definite about it.
  defp epic_working_copy_ids(epic) do
    epic
    |> epic_stories()
    |> Enum.map(& &1.working_copy_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Readiness control for one story on the board.

  # One component for both columns because the board previously gave the same
  # information two different affordances: unfiled stories got a working
  # toggle, stories already inside an epic got a static badge. Flipping one of
  # those meant leaving the board for the epic's Show page — and the board gave no
  # sign of it, so it looked like per-story readiness worked everywhere and
  # silently didn't for exactly the stories just filed.
  #
  # Sharing it also restores the colour the unfiled column had lost: that
  # button carried `badge badge-sm` with no variant, so it read the same
  # whether the story was ready or parked. The badge is the status; it has to
  # look like it.
  attr :story, :map, required: true

  defp story_readiness_toggle(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_story_ready"
      phx-value-id={@story.id}
      data-test={if @story.ready_for_dev == true, do: "story-ready", else: "story-not-ready"}
      title="Toggle readiness for development"
      class={[
        "badge badge-sm shrink-0 cursor-pointer",
        if(@story.ready_for_dev == true, do: "badge-success", else: "badge-ghost")
      ]}
    >
      {if @story.ready_for_dev == true, do: "ready", else: "parked"}
    </button>
    """
  end

  defp noun(1), do: "story"
  defp noun(_), do: "stories"

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@error} role="alert" class="alert alert-error">
      <span>{@error}</span>
    </div>

    <div :if={!@error && @project}>
      <.header>
        Epics
        <:subtitle>
          Drag stories between the columns to file them. Epics organize work —
          filing a story does not release it; the release button does.
        </:subtitle>
        <:actions>
          <.button patch={path(@socket, ~p"/app/projects/#{@slug}/epics/new")} class="btn btn-primary">
            <.icon name="hero-plus" /> New epic
          </.button>
        </:actions>
      </.header>

      <div class="mt-6 grid grid-cols-1 lg:grid-cols-2 gap-6 items-start">
        <%!-- Epics stay in view while the unfiled column scrolls, so a drag
                target is always on screen. --%>
        <div class="flex flex-col gap-4 lg:sticky lg:top-4 lg:max-h-[85vh] lg:overflow-y-auto">
          <div class="local-sidebar-eyebrow">// epics</div>

          <div :if={@epics == []} class="card bg-base-200" data-test="empty-state">
            <div class="card-body">
              <h2 class="card-title text-base">No epics yet</h2>
              <p class="text-sm">Create one, then drag stories into it.</p>
            </div>
          </div>

          <div
            :for={epic <- @epics}
            class={[
              "card bg-base-100 border",
              epic.status == :proposed && "border-primary",
              epic.status != :proposed && "border-base-300"
            ]}
            data-test="epic"
            data-epic-id={epic.id}
            data-epic-status={epic.status}
          >
            <div class="card-body p-4 gap-3">
              <div class="flex items-start justify-between gap-2">
                <div class="min-w-0">
                  <h3 class="font-semibold truncate">{epic.name}</h3>
                  <p class="text-xs opacity-70">
                    {length(epic_stories(epic))} stories · {ready_count(epic)} ready
                  </p>

                  <%!-- What is assigned and what is not. Story 895 put the
                    binding on *stories* — an epic carries no working copy of
                    its own, and its column was dropped when the axis moved
                    down — so this counts its members rather than reading a
                    field.

                    Badges rather than a sentence, and the same badges the
                    stories page uses: this first shipped as `text-xs
                    opacity-70` directly under another `text-xs opacity-70`
                    line, which rendered correctly and read as nothing. John:
                    "I don't see the assignment on the epics screen at all."

                    Unassigned is not a gap to fill: it is the shared backlog
                    every working copy is offered. --%>
                  <div
                    data-test="epic-assignment"
                    data-assigned-count={assigned_count(epic)}
                    class="mt-1 flex flex-wrap items-center gap-1"
                  >
                    <%= case {assigned_count(epic), length(epic_stories(epic))} do %>
                      <% {0, 0} -> %>
                        <span class="text-xs opacity-70">No stories yet</span>
                      <% {0, _total} -> %>
                        <span
                          class="badge badge-ghost badge-sm"
                          title="In the shared backlog — every working copy is offered these"
                        >
                          Unassigned
                        </span>
                      <% {n, n} -> %>
                        <span
                          class="badge badge-info badge-outline badge-sm"
                          title={"All #{n} stories are offered only to this checkout"}
                        >
                          {copy_names(epic, @working_copy_names)}
                        </span>
                      <% {n, total} -> %>
                        <span
                          class="badge badge-info badge-outline badge-sm"
                          title="Offered only to this checkout"
                        >
                          {copy_names(epic, @working_copy_names)}
                        </span>
                        <span
                          class="badge badge-ghost badge-sm"
                          title="In the shared backlog — every working copy is offered these"
                        >
                          {total - n} unassigned
                        </span>
                    <% end %>
                  </div>

                  <%!-- Where the work is happening. An epic dispatched with
                    nowhere to go says so rather than looking finished: the
                    decision was the user's and it stands, but the work has not
                    started. --%>
                  <p
                    :if={epic.status in [:dispatched, :failed]}
                    data-test="epic-working-copy"
                    data-working-copy-id={List.first(epic_working_copy_ids(epic))}
                    class="text-xs opacity-70"
                  >
                    <%= case epic_working_copy_ids(epic) do %>
                      <% [] -> %>
                        Agreed, and waiting for a checkout to build it on
                      <% [_one] -> %>
                        Being built on your project's checkout
                      <% many -> %>
                        Being built across {length(many)} checkouts
                    <% end %>
                  </p>

                  <p
                    :if={epic.status == :failed && epic.failure_reason}
                    data-test="epic-failure"
                    class="text-xs text-warning"
                  >
                    It stopped: {epic.failure_reason}
                  </p>
                </div>
                <div class="flex items-center gap-1 shrink-0">
                  <.button
                    patch={path(@socket, ~p"/app/projects/#{@slug}/epics/#{epic.slug}/edit")}
                    class="btn btn-ghost btn-xs"
                  >
                    Edit
                  </.button>
                  <%!-- Agreeing is what starts work, and it is the only
                    thing that does. Offered only on an epic the agent has
                    actually put forward: a control on a draft would let work
                    start before anybody proposed it. --%>
                  <button
                    :if={epic.status == :proposed}
                    type="button"
                    phx-click="approve_epic"
                    phx-value-id={epic.id}
                    data-test="approve-epic"
                    data-epic-id={epic.id}
                    class="btn btn-primary btn-xs"
                  >
                    Build this
                  </button>
                  <button
                    type="button"
                    phx-click="release_epic"
                    phx-value-id={epic.id}
                    data-test={"release-epic-#{epic.slug}"}
                    class="btn btn-ghost btn-xs text-success"
                  >
                    Release
                  </button>
                  <button
                    type="button"
                    phx-click="park_epic"
                    phx-value-id={epic.id}
                    class="btn btn-ghost btn-xs"
                  >
                    Park
                  </button>
                  <button
                    type="button"
                    phx-click={show_confirm("confirm-delete-epic-#{epic.id}")}
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Delete
                  </button>
                </div>
              </div>

              <p :if={epic.description} class="text-sm opacity-70">{epic.description}</p>

              <ul
                id={"epic-#{epic.id}-dropzone"}
                phx-hook=".EpicBoard"
                data-epic-id={epic.id}
                class="min-h-14 rounded border border-dashed border-base-300 p-2 space-y-2"
              >
                <li
                  :for={story <- epic_stories(epic)}
                  id={"epic-#{epic.id}-story-#{story.id}"}
                  data-story-id={story.id}
                  class="cursor-grab active:cursor-grabbing rounded bg-base-200 px-3 py-2 flex items-center justify-between gap-2"
                >
                  <span class="truncate text-sm">{story.title}</span>
                  <.story_readiness_toggle story={story} />
                </li>
              </ul>
            </div>
          </div>
        </div>

        <div class="flex flex-col gap-4">
          <div class="local-sidebar-eyebrow">// unfiled stories</div>

          <div class="card bg-base-100 border border-base-300">
            <div class="card-body p-4">
              <p class="text-xs opacity-70 mb-2">
                Stories that belong to no epic. Drag one into an epic to file it.
              </p>

              <ul
                id="unassigned-dropzone"
                phx-hook=".EpicBoard"
                data-epic-id=""
                class="min-h-24 max-h-[60vh] overflow-y-auto rounded border border-dashed border-base-300 p-2 space-y-2"
              >
                <li
                  :for={story <- @unassigned}
                  id={"unassigned-story-#{story.id}"}
                  data-story-id={story.id}
                  class="cursor-grab active:cursor-grabbing rounded bg-base-200 px-3 py-2 flex items-center justify-between gap-2"
                >
                  <span class="truncate text-sm">{story.title}</span>
                  <.story_readiness_toggle story={story} />
                </li>
              </ul>

              <p :if={@unassigned == []} class="text-sm opacity-60 mt-2">
                Every story belongs to an epic.
              </p>
            </div>
          </div>
        </div>
      </div>

      <%!-- Confirm dialogs live here, outside the board, on purpose. The
              epics column is `lg:sticky lg:max-h-[85vh] lg:overflow-y-auto` so
              it scrolls independently of the unfiled list — and that scroll
              container clipped the dialog to the column's width, cutting the
              confirm button off the right edge. Rendering them at page level
              keeps them clear of it. --%>
      <.confirm_dialog
        :for={epic <- @epics}
        id={"confirm-delete-epic-#{epic.id}"}
        title={"Delete epic \"#{epic.name}\"?"}
        message="The stories in it are kept — they simply become unfiled."
        confirm_label="Delete"
        on_confirm={JS.push("delete", value: %{id: epic.id})}
      />

      <dialog :if={@live_action in [:new, :edit]} id="epic-form-modal" class="modal modal-open">
        <div class="modal-box max-w-2xl">
          <.live_component
            module={FormComponent}
            id={(@epic && @epic.id) || :new}
            action={@live_action}
            epic={@epic}
            scope={@scope}
            return_to={path(@socket, ~p"/app/projects/#{@slug}/epics")}
          />
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click={JS.patch(path(@socket, ~p"/app/projects/#{@slug}/epics"))}>close</button>
        </form>
      </dialog>
    </div>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".EpicBoard">
      export default {
        mounted() {
          this.sortable = new window.Sortable(this.el, {
            group: "epic-board",
            animation: 150,
            ghostClass: "opacity-40",
            dragClass: "shadow-2xl",

            // `onAdd` fires on the receiving list, so `this.el` is the
            // destination — an epic dropzone, or the unfiled column whose
            // data-epic-id is empty.
            onAdd: (evt) => {
              this.pushEvent("move_story", {
                story_id: evt.item.dataset.storyId,
                epic_id: this.el.dataset.epicId || ""
              })
            }
          })
        },

        destroyed() {
          if (this.sortable) this.sortable.destroy()
        }
      }
    </script>
    """
  end
end
