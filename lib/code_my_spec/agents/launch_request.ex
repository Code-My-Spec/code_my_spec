defmodule CodeMySpec.Agents.LaunchRequest do
  @moduledoc """
  What the server sends a machine to bring one agent up.

  One definition, because there were three and they had already drifted.
  `Transport.Harness` built it for a fresh start, `HarnessProjectChannel` built
  it again for a restore, and the in-process transport the whole spex suite runs
  on built a third — so a field added to the first reached neither of the
  others, and a criterion driving the third proved nothing about the first.

  The drift was not hypothetical. The restore map carried no credential at all,
  so an agent on an API-key provider came back after a harness restart with
  nothing to authenticate with, and failed on its first turn — minutes later, in
  a log nobody reads.

  ## What travels

  What to run and where, the credential, and the conversation so far. Not a
  command: the machine knows what is installed on it and the server does not.

  History is on the wire for the same reason the credential is. An agent dies
  with its harness — that is stated in `CmsHarness.Agents.Engine` and accepted,
  because the transcript is the state. It is only true if the transcript
  actually travels, and until it did, coming back meant coming back empty.

  Both ride on the agent as virtual fields, resolved by `hydrate/2` where there
  is a scope to resolve them from. The row must not become a second place a
  subscription lives, and it must not become a second copy of the transcript
  either.
  """

  alias CodeMySpec.Agents.{Agent, Credential}
  alias CodeMySpec.Conversations
  alias CodeMySpec.Users.Scope

  @doc """
  Fill in the two things a launch needs and the row does not hold.

  Called wherever an agent is about to be sent to a machine — a start, and a
  restore after that machine came back. A restore that skips this sends an agent
  with no credential and no memory, which is the shape this module exists to
  stop shipping.
  """
  @spec hydrate(Scope.t(), Agent.t()) :: Agent.t()
  def hydrate(%Scope{} = scope, %Agent{} = agent) do
    %{
      agent
      | credential: agent.credential || credential(scope, agent),
        history: history(scope, agent)
    }
  end

  @doc """
  The wire map for this agent.

  Reads the virtual fields rather than resolving anything, so what is sent is
  what the caller decided to send. An unhydrated agent produces a request with
  no credential and no history — a first start, which is exactly what it looks
  like.
  """
  @spec for(Agent.t()) :: map()
  def for(%Agent{} = agent) do
    %{
      "agent_id" => agent.id,
      "engine" => to_string(agent.engine),
      "provider" => agent.provider,
      "working_copy" => agent.working_copy,
      "role" => agent.role,
      "messages" => agent.history || []
    }
    |> Map.merge(credential_fields(agent.credential))
  end

  # Where the agent picks up. `resume_messages/1` answers with the whole
  # conversation while it is short enough to hand a model, and from the last
  # compaction checkpoint onward once it is not.
  #
  # A conversation that does not exist yet means an agent that has never spoken,
  # and an empty history is the honest answer rather than a reason to fail: the
  # machine starts it fresh, which is what a first start is.
  defp history(%Scope{} = scope, %Agent{} = agent) do
    case Conversations.find_or_create_agent_conversation(
           scope.active_account_id,
           agent.project_id || scope.active_project_id,
           agent.id
         ) do
      {:ok, conversation} -> Conversations.resume_messages(conversation)
      _error -> []
    end
  end

  defp credential(%Scope{} = scope, %Agent{provider: provider}) when is_binary(provider) do
    case Credential.fetch(scope, provider) do
      {:ok, credential} -> credential
      {:error, _reason} -> %{}
    end
  end

  defp credential(_scope, _agent), do: %{}

  # Only the field the named provider actually uses. An api-key provider has no
  # use for a token pair, and sending both would put a subscription on the wire
  # for a request that did not need it.
  defp credential_fields(%{"type" => "api_key", "key" => key}), do: %{"api_key" => key}
  defp credential_fields(_credential), do: %{}
end
