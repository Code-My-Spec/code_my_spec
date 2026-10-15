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
    released_at = released_at(tasks, story)
    as_of = promoted_at(story) || DateTime.utc_now()

    %{
      status: status(story, tasks),
      released_at: released_at,
      promoted_at: promoted_at(story),
      total_seconds: total_seconds(tasks, story),
      stages: stage_seconds(tasks, released_at, as_of),
      blocked: Enum.flat_map(tasks, &blocked_spans(&1, as_of))
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
  #
  # Restricted to tasks carrying this story's own story_id: `tasks` can also
  # hold a shared component's own tasks (no story_id of their own, see
  # `Sessions.list_tasks_for_story/3`), and a component reused across many
  # stories' builds has one earliest such task that predates all of them --
  # anchoring on it pinned every sibling story to the same Total (issue
  # 04830e20). That shared fallback still flows into `stage_seconds/2`'s
  # build-stage time, which legitimately counts a component's own shared
  # work; it is just not this story's own release moment.
  defp released_at(tasks, %Story{id: story_id, inserted_at: inserted_at}) do
    tasks
    |> Enum.filter(&(&1.story_id == story_id))
    |> Enum.map(& &1.started_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(DateTime, fn -> inserted_at end)
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

  defp stage_seconds(tasks, released_at, as_of) do
    tasks
    |> Enum.group_by(&Stage.of(&1.session_type))
    |> Map.new(fn {stage, stage_tasks} ->
      {stage, active_union_seconds(stage_tasks, released_at, as_of)}
    end)
  end

  # A stage's active time is the wall-clock span its own tasks actually
  # covered, not the sum of each task's own span: several never-completed
  # task records for one stage -- a QA round reopened across harness
  # restarts, say -- can each span most of the story's own life. Clamping
  # each to the story's own window keeps any one of them from running
  # outside it, but summing their spans still double-counts whatever
  # wall-clock time they overlap, so the union is taken instead (issue: a
  # stage reading hours beyond the story's own total).
  defp active_union_seconds(tasks, released_at, as_of) do
    tasks
    |> Enum.flat_map(&active_intervals(&1, released_at, as_of))
    |> merge_intervals()
    |> Enum.reduce(0, fn {from, to}, acc -> acc + DateTime.diff(to, from) end)
  end

  # A task's own active time as intervals, clamped on both ends to the
  # story's own [released_at, as_of] window -- not just its open end.
  # Un-clamped, either edge can put a stage past the story's own total
  # (issue 9c2107a6): a task can start before this story's own release (a
  # shared component's older task, see `released_at/2`'s own fallback), or
  # its `completed_at` can land after this story's own promotion (a QA
  # round stamped completed days after `promoted_at`). Both are clamped
  # the same way the no-completed_at case already was; a task whose own
  # window falls entirely outside the story's contributes nothing.
  defp active_intervals(%{started_at: nil}, _released_at, _as_of), do: []

  defp active_intervals(task, released_at, as_of) do
    start = later(task.started_at, released_at)
    finished = earlier(task.completed_at || as_of, as_of)

    if DateTime.compare(start, finished) == :lt do
      subtract_intervals({start, finished}, blocked_intervals(task, start, finished))
    else
      []
    end
  end

  defp blocked_intervals(%{blocked_at: nil}, _from, _to), do: []

  defp blocked_intervals(task, from, to) do
    blocked_from = later(task.blocked_at, from)
    blocked_to = earlier(task.blocker_resolved_at || to, to)

    if DateTime.compare(blocked_from, blocked_to) == :lt,
      do: [{blocked_from, blocked_to}],
      else: []
  end

  # Cuts `holes` out of `interval`, each assumed to fall inside it -- true
  # here since a task's own blocked span is always within its own
  # open-to-close span.
  defp subtract_intervals(interval, []), do: [interval]

  defp subtract_intervals({from, to}, holes) do
    {cursor, pieces} =
      holes
      |> Enum.sort_by(fn {h_from, _h_to} -> h_from end, DateTime)
      |> Enum.reduce({from, []}, fn {h_from, h_to}, {cursor, pieces} ->
        pieces =
          if DateTime.compare(cursor, h_from) == :lt,
            do: [{cursor, h_from} | pieces],
            else: pieces

        {later(cursor, h_to), pieces}
      end)

    pieces = if DateTime.compare(cursor, to) == :lt, do: [{cursor, to} | pieces], else: pieces
    Enum.reverse(pieces)
  end

  defp later(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earlier(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  # Overlapping or touching intervals become one, so a stage's covered
  # wall-clock time is counted once whatever tasks contributed to it.
  defp merge_intervals(intervals) do
    intervals
    |> Enum.sort_by(fn {from, _to} -> from end, DateTime)
    |> Enum.reduce([], fn {from, to}, acc -> merge_into(acc, from, to) end)
    |> Enum.reverse()
  end

  defp merge_into([{prev_from, prev_to} | rest], from, to) do
    if DateTime.compare(from, prev_to) != :gt do
      [{prev_from, later(prev_to, to)} | rest]
    else
      [{from, to}, {prev_from, prev_to} | rest]
    end
  end

  defp merge_into([], from, to), do: [{from, to}]

  defp blocked_spans(%{blocked_at: nil}, _as_of), do: []

  defp blocked_spans(task, as_of) do
    ended = task.blocker_resolved_at || as_of

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
