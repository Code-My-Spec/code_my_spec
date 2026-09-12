defmodule CodeMySpecWeb.MainAgentConversation do
  @moduledoc """
  A project's own agent, and the conversation it is reached through.

  ## Why there is no longer a path to build

  There used to be a `path/2` here, because the cockpit's URL named a
  conversation — so every link into a project had to resolve one first, and the
  picker could not render a link without deciding, and starting, the agent you
  would land on.

  The cockpit is a project page now (`/app/projects/:id/agent-conversation`,
  with `?conversation=` naming an agent only once you have picked one), so that
  link is an ordinary route its callers build with `~p`. The resolution happens
  on arrival, in the page that needs the answer, which also means rendering a
  link stopped being a thing that starts an agent.

  ## Why this can fail, and what happens when it does

  `Agents.ensure_main_agent/1` answers `{:error, :no_main_working_copy}` for a
  project nobody has onboarded a checkout for yet — there is no copy to run an
  agent in, so there is no main agent and nothing here can invent one. The
  cockpit renders that as its own explanation rather than as an empty
  transcript: "nowhere to run" and "nothing said yet" are different states with
  different remedies, and a single blank screen for both sends half the people
  who see it to the wrong place.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope

  @doc """
  The main agent and its conversation, created if either is missing.

  Public so a page that needs more than the conversation — which working copy
  the agent is in, whether there is an agent at all — can ask the same question
  rather than growing its own copy of these two calls.
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
