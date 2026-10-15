defmodule CodeMySpec.Requirements.QuestionsAnsweredSettleTest do
  @moduledoc """
  dfb8ef8f / 56cf5697 — `questions_answered` had a definition and a graph
  node, but no entry in `@requirement_profiles` and no `settle/3` clause.

  `"story_changed"` is a handled event kind: handling it means the fallback
  safe-recompute is discarded for everything it can move, on the documented
  premise that `settle/3` covers all of it. A requirement missing from both
  registries is not marked stale by that path — it is silently skipped,
  forever, with whatever verdict it happened to have. Measured live: three
  stories stuck `STALE READ` permanently, two of them with
  `questions_answered` as their only gap.

  This pins the fix at the level the bug actually lived at: does
  `apply_event("story_changed", ...)` produce a sweep for
  `questions_answered` at all (it silently would not have before), and does
  that sweep's verdict agree with the delegate checker it is a faster answer
  for.
  """
  use CodeMySpecSpex.Case, async: true

  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]

  alias CodeMySpec.Questions
  alias CodeMySpec.Requirements.BddRulesChecker
  alias CodeMySpec.Requirements.Handlers

  setup :register_log_in_setup_account
  setup :setup_active_project

  defp questions_answered_sweep(scope) do
    {:ok, _changes, sweeps} = Handlers.apply_event(scope, "story_changed", %{})
    Enum.find(sweeps, &(&1.name == "questions_answered"))
  end

  test "a story_changed event covers questions_answered at all", ctx do
    create_story(ctx.scope, title: "Any story", description: "exists so the profile isn't empty")

    refute is_nil(questions_answered_sweep(ctx.scope)),
           "questions_answered is missing from the sweep entirely — this is the exact " <>
             "silent-skip bug: a handled event kind with no settle/3 clause for this " <>
             "requirement leaves it permanently unrecomputed rather than merely wrong"
  end

  test "a story with an open question is named in except, not left on the default", ctx do
    story = create_story(ctx.scope, title: "Has a question", description: "d")
    {:ok, question} = Questions.create_question(ctx.scope, story.id, %{text: "Which customer?"})

    sweep = questions_answered_sweep(ctx.scope)

    assert sweep.default == true,
           "most stories have no open questions, so the cheap answer must be the default"

    exception = Enum.find(sweep.except, &(&1.entity_id == story.id))

    refute is_nil(exception),
           "a story with an open question must be named in the exceptions, not silently " <>
             "left to read as satisfied via the default"

    assert exception.satisfied == false
    assert exception.details["reason"] =~ question.text
  end

  test "a story whose only question was resolved is not named as an exception", ctx do
    story = create_story(ctx.scope, title: "Question resolved", description: "d")
    {:ok, question} = Questions.create_question(ctx.scope, story.id, %{text: "Which customer?"})
    {:ok, _resolved} = Questions.resolve_question(ctx.scope, question, "Acme, per the brief")

    sweep = questions_answered_sweep(ctx.scope)

    assert Enum.find(sweep.except, &(&1.entity_id == story.id)) == nil,
           "a resolved question must not keep the story marked as having an open one"
  end

  test "the settle verdict agrees with the delegate checker it is a faster answer for", ctx do
    story = create_story(ctx.scope, title: "Cross-check", description: "d")
    {:ok, _question} = Questions.create_question(ctx.scope, story.id, %{text: "Which customer?"})

    sweep = questions_answered_sweep(ctx.scope)
    swept_satisfied = is_nil(Enum.find(sweep.except, &(&1.entity_id == story.id)))

    {checker_satisfied, _detail} = BddRulesChecker.questions_answered?(ctx.scope, story)

    assert swept_satisfied == checker_satisfied,
           "the settle sweep and the delegate checker disagree about the same story — " <>
             "exactly the drift the rows-vs-recompute diff exists to catch, and exactly what a " <>
             "missing settle/3 clause produces (the sweep never runs at all rather " <>
             "than running wrong)"
  end
end
