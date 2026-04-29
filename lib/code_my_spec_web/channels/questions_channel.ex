defmodule CodeMySpecWeb.QuestionsChannel do
  @moduledoc """
  Channel for clients to receive real-time question change notifications.

  Clients join with their account ID and receive created/updated/deleted
  events for questions in that account, relayed from the Questions PubSub
  topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.Questions.Question

  @impl true
  def join("questions:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:questions")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:question_created, %Question{} = question}, socket) do
    push(socket, "question_created", serialize_question(question))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:question_updated, %Question{} = question}, socket) do
    push(socket, "question_updated", serialize_question(question))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:question_deleted, %Question{} = question}, socket) do
    push(socket, "question_deleted", %{id: question.id})
    {:noreply, socket}
  end

  defp serialize_question(%Question{} = question) do
    %{
      id: question.id,
      account_id: question.account_id,
      project_id: question.project_id,
      story_id: question.story_id,
      text: question.text,
      status: question.status,
      inserted_at: question.inserted_at,
      updated_at: question.updated_at
    }
  end
end
