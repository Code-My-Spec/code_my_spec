defmodule CodeMySpecWeb.PersonasLive.Show do
  @moduledoc """
  Shows a single persona — DB metadata, linked stories, and (where the project
  is configured) the on-disk research path. Markdown content (`summary.md`,
  `sources.md`) lives in the user's local CLI repo and is not synced to the
  hosted web app.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Personas
  alias CodeMySpec.Stories
  alias CodeMySpecWeb.PersonasLive.FormComponent

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    scope = socket.assigns.current_scope

    case Personas.get_persona_by_slug(scope, slug) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Persona not found")
         |> push_navigate(to: ~p"/app/personas")}

      persona ->
        {:ok, load_state(socket, scope, persona)}
    end
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, _params) do
    assign(socket, :page_title, "Edit Persona")
  end

  defp apply_action(socket, :link, _params) do
    scope = socket.assigns.current_scope

    candidates =
      case scope.active_project do
        %{id: _} -> Stories.list_stories(scope)
        _ -> []
      end

    socket
    |> assign(:page_title, "Link Story")
    |> assign(:link_candidates, candidates)
    |> assign(:link_search, "")
  end

  defp apply_action(socket, _action, _params) do
    assign(socket, :page_title, socket.assigns.persona.name)
  end

  @impl true
  def handle_event("link", %{"story_id" => story_id}, socket) do
    scope = socket.assigns.current_scope
    persona = socket.assigns.persona

    case Personas.link_persona_to_story(scope, persona.id, String.to_integer(story_id)) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Story linked")
         |> load_state(scope, persona)
         |> push_patch(to: ~p"/app/personas/#{persona.slug}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not link: #{inspect(reason)}")}
    end
  end

  def handle_event("unlink", %{"story_id" => story_id}, socket) do
    scope = socket.assigns.current_scope
    persona = socket.assigns.persona

    case Personas.unlink_persona_from_story(scope, persona.id, String.to_integer(story_id)) do
      {:ok, :unlinked} ->
        {:noreply,
         socket
         |> put_flash(:info, "Story unlinked")
         |> load_state(scope, persona)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not unlink: #{inspect(reason)}")}
    end
  end

  def handle_event("filter_link_candidates", %{"q" => q}, socket) do
    {:noreply, assign(socket, :link_search, q)}
  end

  @impl true
  def handle_info({:persona_saved, persona}, socket) do
    {:noreply,
     socket
     |> load_state(socket.assigns.current_scope, persona)
     |> push_patch(to: ~p"/app/personas/#{persona.slug}")}
  end

  defp load_state(socket, scope, persona) do
    linked = Personas.list_stories_for_persona(scope, persona.id)

    socket
    |> assign(:persona, persona)
    |> assign(:linked_stories, linked)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        {@persona.name}
        <:subtitle>
          <span class="badge badge-sm mr-2">{@persona.persona_type}</span>
          {@persona.headline || "No headline"}
        </:subtitle>
        <:actions>
          <.button navigate={~p"/app/personas"} class="btn btn-ghost btn-sm">
            <.icon name="hero-arrow-left" /> Back
          </.button>
          <.button patch={~p"/app/personas/#{@persona.slug}/edit"} class="btn btn-primary btn-sm">
            <.icon name="hero-pencil-square" /> Edit
          </.button>
          <.button patch={~p"/app/personas/#{@persona.slug}/link"} class="btn btn-secondary btn-sm">
            <.icon name="hero-link" /> Link to story
          </.button>
        </:actions>
      </.header>

      <div class="grid grid-cols-1 lg:grid-cols-3 gap-6 mt-6">
        <div class="lg:col-span-2 space-y-4">
          <div class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <h2 class="card-title">Identity</h2>
              <dl class="grid grid-cols-3 gap-2 text-sm">
                <dt class="text-base-content/60">Slug</dt>
                <dd class="col-span-2 font-mono">{@persona.slug}</dd>
                <dt class="text-base-content/60">Type</dt>
                <dd class="col-span-2">{@persona.persona_type}</dd>
                <dt class="text-base-content/60">Created</dt>
                <dd class="col-span-2">{Calendar.strftime(@persona.inserted_at, "%b %d, %Y")}</dd>
              </dl>
            </div>
          </div>

          <div class="card bg-base-200">
            <div class="card-body">
              <h2 class="card-title">Research artifacts</h2>
              <p class="text-sm">
                The full research lives on disk in the local CLI repo, not in the hosted web app:
              </p>
              <ul class="list-disc list-inside text-sm font-mono">
                <li>.code_my_spec/personas/{@persona.slug}/summary.md</li>
                <li>.code_my_spec/personas/{@persona.slug}/sources.md</li>
              </ul>
              <p class="text-xs text-base-content/60 mt-2">
                Open these in your editor or via <code>read_knowledge</code> in an agent session.
              </p>
            </div>
          </div>
        </div>

        <div class="space-y-4">
          <div class="card bg-base-100 border border-base-300">
            <div class="card-body">
              <h2 class="card-title">Linked stories</h2>
              <p :if={@linked_stories == []} class="text-sm text-base-content/60">
                No stories linked yet.
              </p>
              <ul :if={@linked_stories != []} class="space-y-2">
                <li
                  :for={story <- @linked_stories}
                  class="flex items-start justify-between gap-2 text-sm"
                >
                  <span class="flex-1">{story.title}</span>
                  <button
                    phx-click="unlink"
                    phx-value-story_id={story.id}
                    data-confirm="Unlink this story?"
                    class="btn btn-ghost btn-xs text-error"
                  >
                    Unlink
                  </button>
                </li>
              </ul>
            </div>
          </div>
        </div>
      </div>

      <dialog :if={@live_action == :edit} id="persona-form-modal" class="modal modal-open">
        <div class="modal-box max-w-2xl">
          <.live_component
            module={FormComponent}
            id={@persona.id}
            action={:edit}
            persona={@persona}
            scope={@current_scope}
            return_to={~p"/app/personas/#{@persona.slug}"}
          />
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click={JS.patch(~p"/app/personas/#{@persona.slug}")}>close</button>
        </form>
      </dialog>

      <dialog :if={@live_action == :link} id="persona-link-modal" class="modal modal-open">
        <div class="modal-box max-w-2xl">
          <.header>
            Link {@persona.name} to a story
          </.header>

          <div :if={@link_candidates == []} class="alert alert-warning my-4">
            No stories available — pick an active project first to populate the picker.
          </div>

          <form :if={@link_candidates != []} phx-change="filter_link_candidates" class="my-3">
            <input
              type="text"
              name="q"
              value={@link_search}
              placeholder="Search stories..."
              class="input input-bordered w-full"
              autocomplete="off"
            />
          </form>

          <ul :if={@link_candidates != []} class="max-h-96 overflow-y-auto divide-y divide-base-300">
            <li
              :for={story <- filter_stories(@link_candidates, @link_search)}
              class="flex items-center justify-between py-2 gap-2"
            >
              <span class="text-sm flex-1">{story.title}</span>
              <button
                phx-click="link"
                phx-value-story_id={story.id}
                class="btn btn-primary btn-xs"
              >
                Link
              </button>
            </li>
          </ul>
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click={JS.patch(~p"/app/personas/#{@persona.slug}")}>close</button>
        </form>
      </dialog>
    </Layouts.app>
    """
  end

  defp filter_stories(stories, ""), do: stories

  defp filter_stories(stories, q) do
    needle = String.downcase(q)

    Enum.filter(stories, fn s ->
      String.contains?(String.downcase(s.title || ""), needle)
    end)
  end
end
