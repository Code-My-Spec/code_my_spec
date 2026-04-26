defmodule CodeMySpecWeb.PersonasLive.Index do
  @moduledoc """
  Account-scoped persona library. Lists every persona in the active account
  with create / edit / delete actions. Research artifacts (`summary.md`,
  `sources.md`) live on disk in the user's local CLI repo and are not
  surfaced here.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Persona
  alias CodeMySpecWeb.PersonasLive.FormComponent

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    {:ok, load_personas(socket, scope)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :new, _params) do
    socket
    |> assign(:page_title, "New Persona")
    |> assign(:persona, %Persona{persona_type: :proto})
  end

  defp apply_action(socket, :edit, %{"slug" => slug}) do
    case Personas.get_persona_by_slug(socket.assigns.current_scope, slug) do
      nil ->
        socket
        |> put_flash(:error, "Persona not found")
        |> push_patch(to: ~p"/app/personas")

      persona ->
        socket
        |> assign(:page_title, "Edit Persona")
        |> assign(:persona, persona)
    end
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Personas")
    |> assign(:persona, nil)
  end

  @impl true
  def handle_info({:persona_saved, _persona}, socket) do
    {:noreply, load_personas(socket, socket.assigns.current_scope)}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Personas.get_persona(scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Persona not found")}

      persona ->
        case Personas.delete_persona(scope, persona) do
          {:ok, _} ->
            {:noreply,
             socket
             |> put_flash(:info, "Persona deleted")
             |> load_personas(scope)}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Could not delete: #{inspect(reason)}")}
        end
    end
  end

  defp load_personas(socket, scope) do
    assign(socket, :personas, Personas.list_personas(scope))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Personas
        <:subtitle>Account-scoped persona library — research artifacts live on disk in the local CLI repo.</:subtitle>
        <:actions>
          <.button patch={~p"/app/personas/new"} class="btn btn-primary">
            <.icon name="hero-plus" /> New persona
          </.button>
        </:actions>
      </.header>

      <div :if={@personas == []} class="mt-8 card bg-base-200" data-test="empty-state">
        <div class="card-body">
          <h2 class="card-title">No personas yet</h2>
          <p>
            Run a persona research session from the CLI to add one, or click "New persona" above for a quick metadata-only entry.
          </p>
        </div>
      </div>

      <ul :if={@personas != []} class="mt-8 grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-4">
        <li
          :for={persona <- @personas}
          class="card bg-base-100 border border-base-300"
          data-test={"persona-#{persona.slug}"}
        >
          <div class="card-body">
            <div class="flex items-start justify-between gap-2">
              <h3 class="card-title">{persona.name}</h3>
              <span class={"badge badge-sm #{persona_type_badge(persona.persona_type)}"}>
                {persona.persona_type}
              </span>
            </div>
            <p :if={persona.headline} class="text-sm opacity-80">{persona.headline}</p>
            <p class="text-xs font-mono opacity-60">{persona.slug}</p>

            <div class="card-actions justify-end pt-2">
              <.link navigate={~p"/app/personas/#{persona.slug}"} class="btn btn-ghost btn-sm">
                View
              </.link>
              <.button patch={~p"/app/personas/#{persona.slug}/edit"} class="btn btn-ghost btn-sm">
                Edit
              </.button>
              <button
                phx-click="delete"
                phx-value-id={persona.id}
                data-confirm={"Delete persona \"#{persona.name}\"? This removes all story links."}
                class="btn btn-ghost btn-sm text-error"
              >
                Delete
              </button>
            </div>
          </div>
        </li>
      </ul>

      <dialog :if={@live_action in [:new, :edit]} id="persona-form-modal" class="modal modal-open">
        <div class="modal-box max-w-2xl">
          <.live_component
            module={FormComponent}
            id={(@persona && @persona.id) || :new}
            action={@live_action}
            persona={@persona}
            scope={@current_scope}
            return_to={~p"/app/personas"}
          />
        </div>
        <form method="dialog" class="modal-backdrop">
          <button phx-click={JS.patch(~p"/app/personas")}>close</button>
        </form>
      </dialog>
    </Layouts.app>
    """
  end

  defp persona_type_badge(:proto), do: "badge-warning"
  defp persona_type_badge(:qualitative), do: "badge-info"
  defp persona_type_badge(:statistical), do: "badge-success"
  defp persona_type_badge(_), do: "badge-ghost"
end
