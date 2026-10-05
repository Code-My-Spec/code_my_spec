defmodule CodeMySpec.AgentPerformance.QaRounds do
  @moduledoc """
  QA first-pass rate and rework rounds, per story and per team.

  A story's own rounds are its QA attempts in the order QA actually
  submitted them. A team's first-pass rate is the share of its stories
  whose *first* attempt passed -- not the share of all attempts that
  passed, which rewards a team for failing early and often on the way to
  a pass.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.Qa
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type story_rounds :: %{
          measured?: boolean(),
          rounds: non_neg_integer(),
          first_time_pass?: boolean(),
          findings: [String.t()]
        }

  @doc """
  One story's QA rounds: how many, whether the first one passed, and what
  every failed round found.

  A story never submitted to QA is `measured?: false` -- unmeasured, not a
  failed first pass.
  """
  @spec story(Scope.t(), Story.t()) :: story_rounds()
  def story(%Scope{} = scope, %Story{} = story) do
    attempts = scope |> Qa.list_qa_attempts(story.id) |> Enum.reverse()

    case attempts do
      [] ->
        %{measured?: false, rounds: 0, first_time_pass?: false, findings: []}

      [first | _] = all ->
        %{
          measured?: true,
          rounds: length(all),
          first_time_pass?: first.status == :pass,
          findings: all |> Enum.filter(&(&1.status != :pass)) |> Enum.flat_map(&observations/1)
        }
    end
  end

  defp observations(%QaAttempt{scenarios: scenarios}) do
    scenarios
    |> Enum.filter(&(&1.status != :pass))
    |> Enum.map(& &1.observation)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  A team's first-pass rate over a period: the share of its stories whose
  first QA attempt passed.

  Attributed by the *submitting agent's* own `working_copy_id`, not the
  story's: a story's own `working_copy_id` is released the moment the team
  moves on to its next one (`Assignment.fan_out/3`), so by the time this
  reads, a finished story may no longer point back at the team that QA'd it.
  An agent's `working_copy_id` carries no such history and is read regardless
  of whether it is still running, so a retired agent's attempts still count.

  `since` (a `DateTime`) restricts to stories whose first attempt landed
  at or after it; omit for all time.
  """
  @spec team_first_pass_rate(Scope.t(), Ecto.UUID.t(), DateTime.t() | nil) :: float() | nil
  def team_first_pass_rate(%Scope{} = scope, working_copy_id, since \\ nil) do
    agent_copies = scope |> Agents.list_agents() |> Map.new(&{&1.id, &1.working_copy_id})

    first_attempts =
      scope
      |> Qa.list_project_attempts(include_older: true, include_invalidated: true)
      |> Enum.filter(&(Map.get(agent_copies, &1.agent_id) == working_copy_id))
      |> Enum.group_by(& &1.story_id)
      |> Enum.map(fn {_story_id, attempts} -> Enum.min_by(attempts, & &1.submitted_at, DateTime) end)
      |> Enum.filter(&since_cutoff(&1, since))

    case first_attempts do
      [] -> nil
      attempts -> Enum.count(attempts, &(&1.status == :pass)) / length(attempts)
    end
  end

  defp since_cutoff(_attempt, nil), do: true
  defp since_cutoff(%QaAttempt{submitted_at: nil}, _since), do: false
  defp since_cutoff(%QaAttempt{submitted_at: at}, since), do: DateTime.compare(at, since) != :lt
end
