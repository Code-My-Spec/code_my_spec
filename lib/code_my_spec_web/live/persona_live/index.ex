defmodule CodeMySpecWeb.PersonaLive.Index do
  @moduledoc """
  Account-scoped persona library for the hosted web app. Lists every persona
  in the active account. Creation + linking happens via MCP today; a web
  creation form can land here later.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Personas

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope
    personas = Personas.list_personas(scope)

    {:ok,
     socket
     |> assign(personas: personas, page_title: "Personas")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_path={@current_path}>
      <.header>
        Personas
        <:subtitle>Account-scoped persona library — research artifacts live on disk; this view is the canonical list.</:subtitle>
      </.header>

      <div :if={@personas == []} class="mt-8 card bg-base-200" data-test="empty-state">
        <div class="card-body">
          <h2 class="card-title">No personas yet</h2>
          <p>
            Run a persona research session from the CLI to add one. The
            <code>personas_complete</code>
            requirement on the project graph will trigger the agent task when it's the next actionable requirement.
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
          </div>
        </li>
      </ul>
    </Layouts.app>
    """
  end

  defp persona_type_badge(:proto), do: "badge-warning"
  defp persona_type_badge(:qualitative), do: "badge-info"
  defp persona_type_badge(:statistical), do: "badge-success"
  defp persona_type_badge(_), do: "badge-ghost"
end
