defmodule CodeMySpecWeb.PersonasChannel do
  @moduledoc """
  Channel for clients to receive real-time persona change notifications.

  Clients join with their account ID and receive created/updated/deleted
  events for personas plus link/unlink events for persona_stories,
  relayed from the Personas PubSub topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.Personas.Persona
  alias CodeMySpec.Personas.PersonaStory

  @impl true
  def join("personas:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:personas")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:persona_created, %Persona{} = persona}, socket) do
    push(socket, "persona_created", serialize_persona(persona))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:persona_updated, %Persona{} = persona}, socket) do
    push(socket, "persona_updated", serialize_persona(persona))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:persona_deleted, %Persona{} = persona}, socket) do
    push(socket, "persona_deleted", %{id: persona.id})
    {:noreply, socket}
  end

  @impl true
  def handle_info({:persona_linked, %PersonaStory{} = link}, socket) do
    push(socket, "persona_linked", serialize_link(link))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:persona_unlinked, %{persona_id: pid, story_id: sid}}, socket) do
    push(socket, "persona_unlinked", %{persona_id: pid, story_id: sid})
    {:noreply, socket}
  end

  defp serialize_persona(%Persona{} = persona) do
    %{
      id: persona.id,
      slug: persona.slug,
      name: persona.name,
      headline: persona.headline,
      persona_type: persona.persona_type,
      account_id: persona.account_id,
      inserted_at: persona.inserted_at,
      updated_at: persona.updated_at
    }
  end

  defp serialize_link(%PersonaStory{} = link) do
    %{
      id: link.id,
      persona_id: link.persona_id,
      story_id: link.story_id,
      inserted_at: link.inserted_at,
      updated_at: link.updated_at
    }
  end
end
