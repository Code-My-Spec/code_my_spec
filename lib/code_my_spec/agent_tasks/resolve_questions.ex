defmodule CodeMySpec.AgentTasks.ResolveQuestions do
  @moduledoc """
  Clear a story's open questions — issue 56cf5697.

  `three_amigos_complete` reads the seal, not the conversation (deliberately —
  see the prerequisite comment on that node in `RequirementDefinitionData`), so
  a question raised or backfilled against an already-sealed story is invisible
  to it. Nothing else offered that work to anyone either: `StoryExecution`
  blocked the whole story on `questions != []` with no actor named. This is the
  actor. It only exists downstream of the seal — a story that has not sealed
  yet already blocks sealing on the same open questions via
  `BddRulesChecker`'s pre-seal gate, so there is nothing for this task to do
  before that.

  Product already knows how to do this work — measured live, three of five
  ratified from the implementation with citations, no new tool needed. What
  was missing was the graph asking.
  """

  alias CodeMySpec.Questions
  alias CodeMySpec.Requirements.BddRulesChecker
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story

  @spec dispatch(map()) :: String.t()
  def dispatch(_node) do
    "Clear this story's open questions (red cards) — resolve the ones the " <>
      "implementation already answers, using `resolve_question` with the " <>
      "citation as the resolution; escalate the rest with `ask_user_question` " <>
      "when the decision genuinely isn't product's. Use when a sealed story " <>
      "still carries open questions."
  end

  @spec command(term(), map()) :: {:ok, String.t()}
  def command(scope, task) do
    case resolve_story(scope, task) do
      nil -> {:ok, no_story_prompt()}
      story -> {:ok, story_prompt(scope, story)}
    end
  end

  @spec evaluate(term(), map()) :: {:ok, :valid} | {:ok, :invalid, String.t()}
  def evaluate(scope, task) do
    case resolve_story(scope, task) do
      nil ->
        {:ok, :invalid, "Story not provided — evaluate_task needs a resolvable story."}

      story ->
        case BddRulesChecker.questions_answered?(scope, story) do
          {true, _} -> {:ok, :valid}
          {false, %{reason: reason}} -> {:ok, :invalid, reason}
        end
    end
  end

  # Same resolution order as `ThreeAmigos` (three_amigos.ex): a stored
  # `Agent.Task` carries `story_id`, the graph-dispatch route sets
  # `entity_id`. Both land here rather than duplicating the four clauses,
  # since this task is only ever reached one of those two ways.
  defp resolve_story(scope, %{story_id: story_id}) when is_integer(story_id) do
    Stories.get_story(scope, story_id)
  end

  defp resolve_story(scope, %{story_id: story_id}) when is_binary(story_id) do
    fetch_story(scope, story_id)
  end

  defp resolve_story(scope, %{entity_id: entity_id}) when is_binary(entity_id) do
    fetch_story(scope, entity_id)
  end

  defp resolve_story(scope, %{entity_id: entity_id}) when is_integer(entity_id) do
    Stories.get_story(scope, entity_id)
  end

  defp resolve_story(_scope, _task), do: nil

  defp fetch_story(scope, entity_id) do
    case Integer.parse(entity_id) do
      {id, ""} -> Stories.get_story(scope, id)
      _ -> nil
    end
  end

  defp no_story_prompt do
    """
    # Clear Open Questions

    > **Story not provided.** This task should always be scoped to a single
    > story. Ask which story, then call MCP tools with that `story_number`.
    """
  end

  defp story_prompt(scope, %Story{} = story) do
    open =
      scope
      |> Questions.list_questions_for_story(story.id)
      |> Enum.filter(&(&1.status == :open))

    """
    # Clear Open Questions — Story #{story.number}: #{story.title}

    This story's Three Amigos session is already sealed. It still carries
    #{length(open)} open question(s), and nothing else on the graph will ever
    offer them to anyone — that gap is the reason this task exists.

    #{Enum.map_join(open, "\n\n", &question_line/1)}

    ## For each question

    Decide which of these it is:

    - **The implementation already answers it.** Find the module, function or
      line that settles it and call `resolve_question` with `question_id` and
      a `resolution` that cites the evidence — "ratification of an existing
      decision", not a new one.
    - **It's genuinely a decision only the user can make.** Call
      `ask_user_question` — the role's own tools stop at `resolve_question` /
      `list_questions` on purpose, so a wrong answer invented under pressure to
      unblock the story doesn't become the recorded decision instead of an
      open one.

    Do not leave one open because it's easier than either of those two moves.
    Sealing already happened; this task exists only because sealing does not
    also mean the questions were answered.

    Call `evaluate_task` once every open question on this story is resolved or
    escalated.
    """
  end

  defp question_line(question) do
    "- `#{question.id}` — #{question.text}"
  end
end
