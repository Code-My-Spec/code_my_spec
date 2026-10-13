defmodule CodeMySpec.AgentPerformance.Reliability do
  @moduledoc """
  Failed turns, with their cause.

  Only the most recent turn failure survives on the agent record itself
  (`Agent.provider_refusal`/`provider_refused_at`) -- a repeat on every
  turn is recorded once and left, by design (`Agents.record_turn_event/4`
  on a `turn_failed` kind). So this answers "what, if anything, is this
  agent's outstanding failure" rather than a true count over a period;
  a historical tally needs its own record, which does not exist yet.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Users.Scope

  @type failure :: %{at: DateTime.t(), cause: String.t()}

  @doc """
  This agent's outstanding turn failure, if it has one.

  A list of zero or one -- see the moduledoc for why this cannot be a
  count of every turn that failed over a period.
  """
  @spec for_agent(Scope.t(), String.t()) :: [failure()]
  def for_agent(%Scope{} = scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, %{provider_refusal: cause, provider_refused_at: %DateTime{} = at}}
      when is_binary(cause) ->
        [%{at: at, cause: cause}]

      _ ->
        []
    end
  end
end
