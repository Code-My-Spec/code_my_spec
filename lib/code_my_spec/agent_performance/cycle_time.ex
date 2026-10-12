defmodule CodeMySpec.AgentPerformance.CycleTime do
  @moduledoc """
  A story's time from release to promotion, broken down by stage, and the
  time within each stage that went to waiting on a person rather than to
  the work itself.

  Built entirely from `Sessions.Task` -- `started_at`/`completed_at` for a
  stage's own active time, `blocked_at`/`blocker_resolved_at` for the wait
  within it -- rather than a second, separately-maintained clock. A story
  with no tasks yet has no cycle time to report at all.
  """

  alias CodeMySpec.AgentPerformance.Stage
  alias CodeMySpec.Agents
  alias CodeMySpec.Sessions
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @type blocked_span :: %{
          cause: :question | :tap_out | :issue | :manual,
          waiting_on: :user | :main_agent | :another_team,
          seconds: non_neg_integer(),
          resolved?: boolean()
        }

  @type t :: %{
          status: :in_flight | :finished,
          released_at: DateTime.t() | nil,
          promoted_at: DateTime.t() | nil,
          total_seconds: non_neg_integer() | nil,
          stages: %{Stage.t() => non_neg_integer()},
          blocked: [blocked_span()]
        }

  @doc """
  A story's cycle time, broken down by stage, with blocked time named and
  set apart from each stage's own active time.
  """
  @spec story(Scope.t(), Story.t()) :: t()
  def story(%Scope{} = scope, %Story{} = story) do
    story(scope, story, nil)
  end

  @doc """
  A story's cycle time, from tasks already in hand.

  `story/2` asks `Sessions` and `Agents` for this story's tasks, and each of
  those reads the project's sessions and agents and filters in memory. That is
  fine for one story and is why the performance page's chart re-read them once
  per story -- 166 stories over 180 agents is the shape that kept the join past
  the websocket timeout (issue 5d359bb3). A caller with the whole project's
  tasks (`all_tasks/2`) passes them here instead.
  """
  @spec story(Scope.t(), Story.t(), [map()] | nil) :: t()
  def story(%Scope{} = scope, %Story{} = story, tasks) do
    tasks = tasks || all_tasks(scope, story.id, story.component_id)

    %{
      status: status(story, tasks),
      released_at: released_at(tasks, story),
      promoted_at: promoted_at(story),
      total_seconds: total_seconds(tasks, story),
      stages: stage_seconds(tasks),
      blocked: Enum.flat_map(tasks, &blocked_spans/1)
    }
  end

  @doc """
  Every task of every agent and session in the project, in two reads rather
  than two per story.

  The same rows `all_tasks/3` answers for one story, and the same
  `story_id`/`component_id` matching -- just not re-read per story. Pair it
  with `tasks_for/3` to ask `story/3` about any number of stories.
  """
  @spec all_tasks(Scope.t()) :: [map()]
  def all_tasks(%Scope{} = scope) do
    session_tasks = scope |> Sessions.list_sessions() |> Enum.flat_map(&tasks_of/1)
    agent_tasks = scope |> Agents.list_agents() |> Enum.flat_map(&tasks_of/1)

    session_tasks ++ agent_tasks
  end

  @doc "The slice of `all_tasks/1` that belongs to one story."
  @spec tasks_for([map()], integer(), Ecto.UUID.t() | nil) :: [map()]
  def tasks_for(tasks, story_id, component_id \\ nil) do
    Enum.filter(tasks, fn task ->
      task.story_id == story_id or
        (not is_nil(component_id) and task.component_id == component_id)
    end)
  end

  defp tasks_of(owner), do: owner.tasks |> List.wrap() |> Enum.map(&Map.from_struct/1)


  defp status(%Story{promoted_version: nil}, _tasks), do: :in_flight
  defp status(%Story{}, _tasks), do: :finished

  # Tasks live on whichever owner ran them: a session-backed agent (Claude
  # Code, hooks) or an agent run directly under Alloy, with no session at
  # all. A story's build moves through both over its life.
  defp all_tasks(scope, story_id, component_id) do
    Sessions.list_tasks_for_story(scope, story_id, component_id) ++
      Agents.list_tasks_for_story(scope, story_id, component_id)
  end

  # The earliest task opened against the story, as a proxy for "released":
  # nothing on `Story` stamps the moment `ready_for_dev` flipped, and the
  # first unit of real work starting is the closest thing on record to it.
  defp released_at([], %Story{inserted_at: at}), do: at

  defp released_at(tasks, _story) do
    tasks
    |> Enum.map(& &1.started_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> nil end)
  end

  # New promotions carry a permanent timestamp; retain the legacy estimate
  # for stories promoted before that history was recorded.
  defp promoted_at(%Story{promoted_version: nil}), do: nil
  defp promoted_at(%Story{} = story), do: story.promoted_at || story.updated_at

  defp total_seconds([], _story), do: nil

  defp total_seconds(tasks, story) do
    case released_at(tasks, story) do
      nil -> nil
      from -> DateTime.diff(promoted_at(story) || DateTime.utc_now(), from)
    end
  end

  defp stage_seconds(tasks) do
    tasks
    |> Enum.group_by(&Stage.of(&1.session_type))
    |> Map.new(fn {stage, stage_tasks} ->
      {stage, Enum.sum(Enum.map(stage_tasks, &active_seconds/1))}
    end)
  end

  # A task's own active time: wall time open, minus whatever of that was
  # spent blocked on a person rather than worked.
  defp active_seconds(%{started_at: nil}), do: 0

  defp active_seconds(task) do
    finished = task.completed_at || DateTime.utc_now()
    total = DateTime.diff(finished, task.started_at)
    blocked = task |> blocked_spans() |> Enum.map(& &1.seconds) |> Enum.sum()
    max(total - blocked, 0)
  end

  defp blocked_spans(%{blocked_at: nil}), do: []

  defp blocked_spans(task) do
    ended = task.blocker_resolved_at || DateTime.utc_now()

    [
      %{
        cause: task.blocker_type,
        waiting_on: waiting_on(task.blocker_type),
        seconds: DateTime.diff(ended, task.blocked_at),
        resolved?: not is_nil(task.blocker_resolved_at)
      }
    ]
  end

  # A tap-out and a question both wait on the user first; after the
  # project's own recovery interval an undecided tap-out becomes the main
  # agent's to settle too (story 1060). That escalation lives on the
  # permission record, not on the task, so it is not distinguished here --
  # every tap-out and question is shown as waiting on the user.
  defp waiting_on(:issue), do: :another_team
  defp waiting_on(_cause), do: :user
end
