defmodule CodeMySpecWeb.PersonasLive.Index do
  @moduledoc """
  Project-scoped persona library for the local app. Lists every persona for
  the active project with create / edit / delete actions. Research artifacts
  (`summary.md`, `sources.md`) live on disk under `.code_my_spec/personas/`.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Personas
  alias CodeMySpec.Personas.Persona
  alias CodeMySpecWeb.PersonasLive.FormComponent

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :personas,
       error: nil,
       page_title: "Personas",
       personas: [],
       persona: nil
     )}
  end

  @impl true
  def handle_params(params, _url, %{assigns: %{scope: %{} = scope}} = socket) do
    {:noreply,
     socket
     |> load_personas(scope)
     |> apply_action(socket.assigns.live_action, params, scope)}
  end

  def handle_params(_params, _url, socket), do: {:noreply, socket}

  defp apply_action(socket, :new, _params, _scope) do
    socket
    |> assign(:page_title, "New Persona")
    |> assign(:persona, %Persona{persona_type: :proto})
  end

  defp apply_action(socket, :edit, %{"slug" => slug}, scope) do
    case Personas.get_persona_by_slug(scope, slug) do
      nil ->
        socket
        |> put_flash(:error, "Persona not found")
        |> push_patch(to: path(socket, ~p"/app/projects/#{socket.assigns.slug}/personas"))

      persona ->
        socket
        |> assign(:page_title, "Edit Persona")
        |> assign(:persona, persona)
    end
  end

  defp apply_action(socket, :index, _params, _scope) do
    socket
    |> assign(:page_title, "Personas")
    |> assign(:persona, nil)
  end

  @impl true
  def handle_info({:persona_saved, _persona}, socket) do
    {:noreply, load_personas(socket, socket.assigns.scope)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.scope

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
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @project}>
        <.header>
          Personas
          <:subtitle>
            Project-scoped persona library — research artifacts live on disk under
            <code>.code_my_spec/personas/</code>.
          </:subtitle>
          <:actions>
            <.button patch={path(@socket, ~p"/app/projects/#{@slug}/personas/new")} class="btn btn-primary">
              <.icon name="hero-plus" /> New persona
            </.button>
          </:actions>
        </.header>

        <div :if={@personas == []} class="mt-8 card bg-base-200" data-test="empty-state">
          <div class="card-body">
            <h2 class="card-title">No personas yet</h2>
            <p>
              Run a persona research session in the agent to add one, or click "New persona" above for a quick metadata-only entry.
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
                <.link
                  navigate={path(@socket, ~p"/app/projects/#{@slug}/personas/#{persona.slug}")}
                  class="btn btn-ghost btn-sm"
                >
                  View
                </.link>
                <.button
                  patch={path(@socket, ~p"/app/projects/#{@slug}/personas/#{persona.slug}/edit")}
                  class="btn btn-ghost btn-sm"
                >
                  Edit
                </.button>
                <button
                  type="button"
                  phx-click={show_confirm("confirm-delete-persona-#{persona.id}")}
                  class="btn btn-ghost btn-sm text-error"
                >
                  Delete
                </button>
                <.confirm_dialog
                  id={"confirm-delete-persona-#{persona.id}"}
                  title={"Delete persona \"#{persona.name}\"?"}
                  message="This removes the persona and all story links."
                  confirm_label="Delete"
                  on_confirm={JS.push("delete", value: %{id: persona.id})}
                />
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
              scope={@scope}
              return_to={path(@socket, ~p"/app/projects/#{@slug}/personas")}
            />
          </div>
          <form method="dialog" class="modal-backdrop">
            <button phx-click={JS.patch(path(@socket, ~p"/app/projects/#{@slug}/personas"))}>close</button>
          </form>
        </dialog>
      </div>
    """
  end

  defp persona_type_badge(:proto), do: "badge-warning"
  defp persona_type_badge(:qualitative), do: "badge-info"
  defp persona_type_badge(:statistical), do: "badge-success"
  defp persona_type_badge(_), do: "badge-ghost"

end
