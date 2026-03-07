defmodule CodeMySpecWeb.StoriesChannel do
  @moduledoc """
  Channel for clients to receive real-time story change notifications.

  Clients join with their account ID and receive created/updated/deleted
  events for stories in that account, relayed from the Stories PubSub topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.Stories.Story

  @impl true
  def join("stories:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:stories")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:created, %Story{} = story}, socket) do
    push(socket, "story_created", serialize_story(story))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:updated, %Story{} = story}, socket) do
    push(socket, "story_updated", serialize_story(story))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:deleted, %Story{} = story}, socket) do
    push(socket, "story_deleted", %{id: story.id})
    {:noreply, socket}
  end

  defp serialize_story(%Story{} = story) do
    %{
      id: story.id,
      title: story.title,
      description: story.description,
      status: story.status,
      priority: story.priority,
      project_id: story.project_id,
      component_id: story.component_id,
      inserted_at: story.inserted_at,
      updated_at: story.updated_at
    }
  end
end
