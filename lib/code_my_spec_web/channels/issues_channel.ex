defmodule CodeMySpecWeb.IssuesChannel do
  @moduledoc """
  Channel for clients to receive real-time issue change notifications.

  Clients join with their account ID and receive created/accepted/dismissed
  events for issues in that account, relayed from the Issues PubSub topic.
  """
  use CodeMySpecWeb, :channel

  alias CodeMySpec.Issues.Issue

  @impl true
  def join("issues:" <> account_id, _payload, socket) do
    scope = socket.assigns[:scope]

    if scope && scope.active_account_id == account_id do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{account_id}:issues")
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({:created, %Issue{} = issue}, socket) do
    push(socket, "issue_created", serialize_issue(issue))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:accepted, %Issue{} = issue}, socket) do
    push(socket, "issue_accepted", serialize_issue(issue))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:dismissed, %Issue{} = issue}, socket) do
    push(socket, "issue_dismissed", serialize_issue(issue))
    {:noreply, socket}
  end

  @impl true
  def handle_info({:resolved, %Issue{} = issue}, socket) do
    push(socket, "issue_resolved", serialize_issue(issue))
    {:noreply, socket}
  end

  defp serialize_issue(%Issue{} = issue) do
    %{
      id: issue.id,
      title: issue.title,
      severity: issue.severity,
      scope: issue.scope,
      source: issue.source,
      description: issue.description,
      status: issue.status,
      story_id: issue.story_id,
      project_id: issue.project_id,
      inserted_at: issue.inserted_at,
      updated_at: issue.updated_at
    }
  end
end
