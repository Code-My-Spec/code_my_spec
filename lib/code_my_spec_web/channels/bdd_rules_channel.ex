defmodule CodeMySpecWeb.BddRulesChannel do
  @moduledoc """
  Channel for clients to receive real-time BDD rule change notifications.

  Clients join with their account ID and receive created/updated/deleted
  events for rules in that account, relayed from the BddRules PubSub topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.BddRules.Rule

  @impl true
  def join("bdd_rules:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:bdd_rules")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:bdd_rule_created, %Rule{} = rule}, socket) do
    push(socket, "bdd_rule_created", serialize_rule(rule))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:bdd_rule_updated, %Rule{} = rule}, socket) do
    push(socket, "bdd_rule_updated", serialize_rule(rule))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:bdd_rule_deleted, %Rule{} = rule}, socket) do
    push(socket, "bdd_rule_deleted", %{id: rule.id})
    {:noreply, socket}
  end

  defp serialize_rule(%Rule{} = rule) do
    %{
      id: rule.id,
      account_id: rule.account_id,
      project_id: rule.project_id,
      story_id: rule.story_id,
      statement: rule.statement,
      inserted_at: rule.inserted_at,
      updated_at: rule.updated_at
    }
  end
end
