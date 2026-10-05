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
          status: :in_flight | :finished | :no_tasks,
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
    tasks = Sessions.list_tasks_for_story(scope, story.id)

    %{
      status: status(story, tasks),
      released_at: released_at(tasks, story),
      promoted_at: promoted_at(story),
      total_seconds: total_seconds(tasks, story),
      stages: stage_seconds(tasks),
      blocked: Enum.flat_map(tasks, &blocked_spans/1)
    }
  end

  defp status(_story, []), do: :no_tasks
  defp status(%Story{promoted_version: nil}, _tasks), do: :in_flight
  defp status(%Story{}, _tasks), do: :finished

  # The earliest task opened against the story, as a proxy for "released":
  # nothing on `Story` stamps the moment `ready_for_dev` flipped, and the
  # first unit of real work starting is the closest thing on record to it.
  defp released_at([], %Story{inserted_at: at}), do: at

  defp released_at(tasks, _story) do
    tasks |> Enum.map(& &1.started_at) |> Enum.reject(&is_nil/1) |> Enum.min(DateTime, fn -> nil end)
  end

  # Nothing stamps the moment of promotion either; `updated_at` is the last
  # write to the row, and a promotion stamping `promoted_version` is that
  # write for every story that reaches this branch at all.
  defp promoted_at(%Story{promoted_version: nil}), do: nil
  defp promoted_at(%Story{updated_at: at}), do: at

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
    |> Map.new(fn {stage, stage_tasks} -> {stage, Enum.sum(Enum.map(stage_tasks, &active_seconds/1))} end)
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
