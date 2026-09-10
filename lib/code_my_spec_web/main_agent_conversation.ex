defmodule CodeMySpecWeb.MainAgentConversation do
  @moduledoc """
  Where a project's own agent conversation lives, or the index when there is
  not one yet.

  `AgentConversationLive.Index` already resolves this — a main agent, and its
  conversation, created if either is missing — to build one link on a page
  that also lists every other agent. Every place that sends someone *into* a
  project (the picker, the sidebar) wants the same answer without wanting the
  list: John, on where a project should land you, "the agent conversation for
  the main agent of the project" — not a page that still makes you pick one.

  So this is that resolution, pulled out to where both callers can reach it,
  rather than the picker growing its own second copy of `ensure_main_agent/1`
  plus `find_or_create_agent_conversation/3` with nothing keeping the two in
  step.

  ## Why this can fail, and what happens when it does

  `Agents.ensure_main_agent/1` answers `{:error, :no_main_working_copy}` for a
  project nobody has onboarded a checkout for yet — there is no copy to run an
  agent in, so there is no main agent and nothing here can invent one. `path/2`
  falls back to the index in that case: it renders its own explanation, and a
  project with no checkout is precisely the state it already has to handle for
  the "open a project" list, which cannot know in advance which projects have
  one.
  """

  use CodeMySpecWeb, :verified_routes

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  @doc """
  The path into this project's main agent conversation, or its index.

  `scope` must already be resolved to `project` — callers that switch projects
  read from a picker or a list rather than a scope already carrying the target,
  so this takes `project` explicitly instead of trusting `scope.active_project`
  to agree with it.
  """
  @spec path(Scope.t(), Project.t()) :: String.t()
  def path(%Scope{} = scope, %Project{} = project) do
    scope = %{scope | active_project: project, active_project_id: project.id}

    case ensure(scope) do
      {:ok, _agent, conversation} ->
        ~p"/app/projects/#{project.id}/agent-conversation/#{conversation.id}"

      {:error, _reason} ->
        ~p"/app/projects/#{project.id}/agent-conversation"
    end
  end

  @doc """
  The main agent and its conversation, created if either is missing.

  Public so a page that needs more than the path — which working copy the
  agent is in, whether to render a link at all — can ask the same question
  `path/2` answers, rather than growing its own copy of these two calls.
  """
  @spec ensure(Scope.t()) ::
          {:ok, Agents.Agent.t(), Conversations.Conversation.t()} | {:error, term()}
  def ensure(%Scope{} = scope) do
    with {:ok, agent} <- Agents.ensure_main_agent(scope),
         {:ok, conversation} <-
           Conversations.find_or_create_agent_conversation(
             scope.active_account_id,
             scope.active_project_id,
             agent.id
           ) do
      {:ok, agent, conversation}
    end
  end
end
