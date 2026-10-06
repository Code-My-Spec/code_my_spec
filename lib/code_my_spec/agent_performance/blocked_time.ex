defmodule CodeMySpec.AgentPerformance.BlockedTime do
  @moduledoc """
  Time agents spend blocked, by cause and by who they are waiting on --
  independent of any story, since an agent can ask before one is ever
  selected (criterion 2006) and a wait can outlive the task that raised it
  (criterion 2007).

  Reads `Agents.Main`'s own open-question listing rather than a second query
  over `question_requests`/`permission_requests`: that listing is already
  "what is this agent waiting on, and since when", with the same aging and
  escalation rules `StopDecision.wake/2` itself obeys, so this does not grow
  a second opinion about it.
  """

  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.Main.OpenQuestion
  alias CodeMySpec.Users.Scope

  @type blocked_span :: %{
          cause: :question | :tap_out,
          waiting_on: :user | :main_agent,
          seconds: non_neg_integer(),
          resolved?: boolean()
        }

  @doc "Every wait currently open on this project, none of it resolved yet."
  @spec project_level(Scope.t()) :: [blocked_span()]
  def project_level(%Scope{} = scope) do
    scope
    |> MainAgent.list_open_questions()
    |> Enum.map(&span/1)
  end

  defp span(%OpenQuestion{} = open) do
    %{
      cause: cause(open.kind),
      waiting_on: waiting_on(open.holder),
      seconds: DateTime.diff(DateTime.utc_now(), open.asked_at),
      resolved?: false
    }
  end

  defp cause(:permission), do: :tap_out
  defp cause(:question), do: :question

  defp waiting_on("main_agent"), do: :main_agent
  defp waiting_on(_), do: :user
end
