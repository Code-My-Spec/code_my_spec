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

  alias CodeMySpec.Epics
  alias CodeMySpec.Epics.Epic
  alias CodeMySpec.Stories
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
       epic: nil
     )}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{scope: %{} = scope}} = socket) do
    {:noreply,
     socket
     |> load_board(scope)
     |> apply_action(socket.assigns.live_action, params, scope)}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

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
      nil ->
        {:noreply, put_flash(socket, :error, "Epic not found")}

      epic ->
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
  end

  defp epic_stories(epic) do
    if Ecto.assoc_loaded?(epic.stories),
      do: Enum.sort_by(epic.stories, & &1.title),
      else: []
  end

  defp ready_count(epic), do: Enum.count(epic_stories(epic), &(&1.ready_for_dev == true))

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
              class="card bg-base-100 border border-base-300"
              data-test={"epic-#{epic.slug}"}
            >
              <div class="card-body p-4 gap-3">
                <div class="flex items-start justify-between gap-2">
                  <div class="min-w-0">
                    <h3 class="font-semibold truncate">{epic.name}</h3>
                    <p class="text-xs opacity-70">
                      {length(epic_stories(epic))} stories · {ready_count(epic)} ready
                    </p>
                  </div>
                  <div class="flex items-center gap-1 shrink-0">
                    <.button
                      patch={path(@socket, ~p"/app/projects/#{@slug}/epics/#{epic.slug}/edit")}
                      class="btn btn-ghost btn-xs"
                    >
                      Edit
                    </.button>
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
