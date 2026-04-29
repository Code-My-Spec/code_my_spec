defmodule CodeMySpecWeb.AcceptanceCriteriaChannel do
  @moduledoc """
  Channel for clients to receive real-time acceptance criterion change
  notifications.

  Clients join with their account ID and receive created/updated/deleted
  events for criteria in that account, relayed from the AcceptanceCriteria
  PubSub topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.AcceptanceCriteria.Criterion

  @impl true
  def join("criteria:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:acceptance_criteria")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:created, %Criterion{} = criterion}, socket) do
    push(socket, "criterion_created", serialize_criterion(criterion))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:updated, %Criterion{} = criterion}, socket) do
    push(socket, "criterion_updated", serialize_criterion(criterion))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:deleted, %Criterion{} = criterion}, socket) do
    push(socket, "criterion_deleted", %{id: criterion.id})
    {:noreply, socket}
  end

  defp serialize_criterion(%Criterion{} = criterion) do
    %{
      id: criterion.id,
      description: criterion.description,
      body: criterion.body,
      kind: criterion.kind,
      verified: criterion.verified,
      verified_at: criterion.verified_at,
      story_id: criterion.story_id,
      project_id: criterion.project_id,
      rule_id: criterion.rule_id,
      inserted_at: criterion.inserted_at,
      updated_at: criterion.updated_at
    }
  end
end
