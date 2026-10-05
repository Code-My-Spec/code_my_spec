defmodule CodeMySpec.AgentPerformance do
  @moduledoc """
  Aggregates agent throughput, QA pass rate, question/tap-out time, offer
  health, reliability and cost into a performance report.

  Token use per turn, per agent and per provider (story 1092 criteria
  1976-1979) is not here yet: nothing persists a turn's token usage, and
  that needs a schema of its own rather than a read of one that already
  exists. Everything else in this module reads data that already exists
  elsewhere -- `Sessions.Task`, `Qa.QaAttempt`, `Agents.Offer`,
  `Conversations.Message` -- and does not write anything.
  """

  alias CodeMySpec.AgentPerformance.CycleTime
  alias CodeMySpec.AgentPerformance.Interventions
  alias CodeMySpec.AgentPerformance.OfferHealth
  alias CodeMySpec.AgentPerformance.QaRounds
  alias CodeMySpec.AgentPerformance.Reliability
  alias CodeMySpec.AgentPerformance.Throughput
  alias CodeMySpec.AgentPerformance.ToolFailures
  alias CodeMySpec.Agents
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type agent_row :: %{
          agent_id: String.t(),
          role: atom(),
          provider: String.t() | nil,
          tool_failures: ToolFailures.report(),
          reliability: [Reliability.failure()]
        }

  @type summary :: %{
          agents: [agent_row()],
          offer_health: [OfferHealth.role_health()],
          throughput_by_team: %{Ecto.UUID.t() => non_neg_integer()},
          project_level_interventions: [Interventions.intervention()]
        }

  @doc """
  The project-wide summary the index page reads: one row per agent plus
  project totals. `since` restricts offer health and throughput to that
  period; omit for all time.
  """
  @spec summary(Scope.t(), DateTime.t() | nil) :: summary()
  def summary(%Scope{} = scope, since \\ nil) do
    %{
      agents: scope |> Agents.list_agents() |> Enum.map(&agent_row(scope, &1)),
      offer_health: OfferHealth.by_role(scope, since),
      throughput_by_team: Throughput.by_team(scope, since),
      project_level_interventions: Interventions.project_level(scope)
    }
  end

  defp agent_row(scope, agent) do
    %{
      agent_id: agent.id,
      role: agent.role,
      provider: agent.provider,
      tool_failures: ToolFailures.for_agent(scope, agent.id),
      reliability: Reliability.for_agent(scope, agent.id)
    }
  end

  @type agent_detail :: %{
          agent: Agents.Agent.t(),
          tool_failures: ToolFailures.report(),
          reliability: [Reliability.failure()],
          interventions: [Interventions.intervention()]
        }

  @doc "One agent in detail, for the show page. `nil` if no such agent exists."
  @spec agent_detail(Scope.t(), String.t()) :: agent_detail() | nil
  def agent_detail(%Scope{} = scope, agent_id) do
    case Agents.fetch_agent(scope, agent_id) do
      {:ok, agent} ->
        %{
          agent: agent,
          tool_failures: ToolFailures.for_agent(scope, agent_id),
          reliability: Reliability.for_agent(scope, agent_id),
          interventions: Interventions.for_agent(scope, agent_id)
        }

      _ ->
        nil
    end
  end

  @type story_report :: %{
          cycle_time: CycleTime.t(),
          qa_rounds: QaRounds.story_rounds(),
          interventions: [Interventions.intervention()]
        }

  @doc "A story's cycle time, QA rounds and interventions."
  @spec story_report(Scope.t(), Story.t()) :: story_report()
  def story_report(%Scope{} = scope, %Story{} = story) do
    %{
      cycle_time: CycleTime.story(scope, story),
      qa_rounds: QaRounds.story(scope, story),
      interventions: Interventions.story(scope, story)
    }
  end

  @doc "A team's first-pass rate over a period. `since` omitted for all time."
  @spec team_first_pass_rate(Scope.t(), Ecto.UUID.t(), DateTime.t() | nil) :: float() | nil
  def team_first_pass_rate(%Scope{} = scope, working_copy_id, since \\ nil) do
    QaRounds.team_first_pass_rate(scope, working_copy_id, since)
  end

  @doc "Every story this project holds, for building a performance report over all of them."
  @spec list_stories(Scope.t()) :: [Story.t()]
  def list_stories(%Scope{} = scope), do: Stories.list_project_stories(scope)
end
