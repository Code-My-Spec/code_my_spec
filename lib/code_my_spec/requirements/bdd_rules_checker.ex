defmodule CodeMySpec.Requirements.BddRulesChecker do
  @moduledoc """
  Delegate checkers for the story graph's Three Amigos requirements:
  `three_amigos_complete` reads `sealed?/3`, `questions_answered` reads
  `questions_answered?/3`, and `complete?/2,3` is the readiness bar
  `ThreeAmigos.evaluate/2` seals on:

    * ≥1 persona linked via `persona_stories`
    * ≥1 Rule (blue card) on the story
    * `rules < 15` — the Example Mapping ceiling; from 10 rules on, a
      non-blocking advisory suggests splitting the story
    * Every Rule has at least one scenario of any kind — agents must not
      fabricate failure-path examples to satisfy a coverage gate when
      the failure surface lives at a different layer
    * No question (red card) left `:open`

  Returns `{boolean(), map()}` per the checker contract (see
  `IssuesChecker`, `PersonasChecker`). Failure reasons are a markdown
  detail string so stop-hook feedback can direct the next turn.
  Scenario quality is not checked.
  """

  alias CodeMySpec.BddRules
  alias CodeMySpec.Personas
  alias CodeMySpec.Questions
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @rule_ceiling 15
  @rule_advisory_threshold 10

  @doc """
  The same verdict, from a preloaded context (the four collections grouped by
  story id) instead of four queries per story. The gaps are computed by the
  same functions either way. A missing collection reads as empty.
  """
  @spec complete?(Scope.t(), term(), map()) :: {boolean(), map()}
  def complete?(%Scope{active_account_id: account_id}, %Story{id: story_id} = story, ctx)
      when not is_nil(account_id) and not is_nil(story_id) and is_map(ctx) do
    evaluate(
      story,
      Map.get(ctx[:personas_by_story] || %{}, story_id, []),
      Map.get(ctx[:rules_by_story] || %{}, story_id, []),
      Map.get(ctx[:criteria_by_story] || %{}, story_id, []),
      Map.get(ctx[:questions_by_story] || %{}, story_id, [])
    )
  end

  def complete?(scope, entity, _ctx), do: complete?(scope, entity)

  @doc """
  Whether this story's Three Amigos session has been sealed.

  What `three_amigos_complete` reads. Deliberately a different question from
  `complete?/2`, which asks whether the story *would* seal right now:

    * `complete?` is the bar. `ThreeAmigos.evaluate/2` calls it, and seals on a
      pass — so sealing cannot happen while a red card is open.
    * `sealed?` is the record. Once set it stays set, and a question raised
      afterwards does not unset it.

  A seal is a statement about a conversation that happened: recomputing the bar
  here would let a later red card un-ship a shipped story.
  See knowledge/requirements_graph/checkers, "Three Amigos".
  """
  @spec sealed?(Scope.t(), term(), map()) :: {boolean(), map()}
  def sealed?(scope, entity, _ctx), do: sealed?(scope, entity)

  @spec sealed?(Scope.t(), term()) :: {boolean(), map()}
  def sealed?(_scope, %Story{three_amigos_sealed: true}),
    do: {true, %{status: "Three Amigos sealed"}}

  def sealed?(scope, %Story{} = story) do
    # Re-read before concluding "not sealed": `ThreeAmigos.evaluate/2` seals
    # mid-request and then re-checks from a story loaded before the seal.
    case Stories.get_story(scope, story.id) do
      %Story{three_amigos_sealed: true} ->
        {true, %{status: "Three Amigos sealed"}}

      _ ->
        unsealed_reason(scope, story)
    end
  end

  def sealed?(_scope, _entity),
    do: {false, %{reason: "No active scope or invalid story entity — cannot check Three Amigos."}}

  @doc """
  Whether every question raised against this story is answered — none left
  `:open`, resolved or deferred.

  Distinct from `sealed?/2`, which ignores questions raised after the seal.
  This makes those questions somebody's work: `questions_answered` reads it,
  satisfied by `AgentTasks.ResolveQuestions`, downstream of the seal.
  """
  @spec questions_answered?(Scope.t(), term(), map()) :: {boolean(), map()}
  def questions_answered?(scope, entity, _ctx), do: questions_answered?(scope, entity)

  @spec questions_answered?(Scope.t(), term()) :: {boolean(), map()}
  def questions_answered?(scope, %Story{} = story) do
    case Questions.list_questions_for_story(scope, story.id)
         |> Enum.filter(&(&1.status == :open)) do
      [] ->
        {true, %{status: "No open questions"}}

      open ->
        {false,
         %{reason: "#{length(open)} open question(s): " <> Enum.map_join(open, "; ", & &1.text)}}
    end
  end

  def questions_answered?(_scope, _entity),
    do: {false, %{reason: "No active scope or invalid story entity — cannot check questions."}}

  @doc """
  Why a story that is not sealed is not sealed.

  Public for `Requirements.Handlers`, which knows which stories are unsealed
  and needs this wording without a second copy of it.

  The context is `complete?/3`'s, and required: an empty context reads as four
  empty collections, not as "ask".
  """
  @spec unsealed_reason(Scope.t(), Story.t(), map()) :: {false, map()}
  def unsealed_reason(scope, story, ctx) when is_map(ctx),
    do: scope |> complete?(story, ctx) |> seal_gap()

  defp unsealed_reason(scope, story), do: scope |> complete?(story) |> seal_gap()

  # The bar it has not cleared, because "not sealed" on its own tells nobody
  # what to do about it.
  defp seal_gap({true, _meta}),
    do:
      {false,
       %{
         reason:
           "Three Amigos is ready to seal but has not been sealed. Evaluate the " <>
             "three_amigos_complete task to seal it."
       }}

  defp seal_gap({false, meta}), do: {false, meta}

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_account_id: account_id} = scope, %Story{id: story_id} = story)
      when not is_nil(account_id) and not is_nil(story_id) do
    evaluate(
      story,
      Personas.list_personas_for_story(scope, story_id),
      BddRules.list_rules_for_story(scope, story_id),
      AcceptanceCriteria.list_story_criteria(scope, story_id),
      Questions.list_questions_for_story(scope, story_id)
    )
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active scope or invalid story entity — cannot check Three Amigos."}}
  end

  # The verdict itself, from the four collections however they were fetched.
  # Both `complete?/2` and `complete?/3` land here, so a preloaded run and a
  # querying run cannot disagree about what those collections mean.
  defp evaluate(story, personas, rules, criteria, questions) do
    # Only kind-tagged criteria are Three Amigos scenarios (green cards).
    # Legacy / fixture-default AC without `kind` don't participate in the
    # readiness gate.
    scenarios = Enum.filter(criteria, &(not is_nil(&1.kind)))

    gaps =
      []
      |> maybe_add_persona_gap(personas)
      |> maybe_add_rules_gap(rules)
      |> maybe_add_rules_ceiling_gap(rules)
      |> maybe_add_uncovered_rules_gap(rules, scenarios)
      |> maybe_add_questions_gap(scenarios, questions)

    advisory = build_rules_advisory(rules)

    case {gaps, advisory} do
      {[], nil} ->
        {true,
         %{
           status:
             "Three Amigos complete: #{length(personas)} persona(s), #{length(rules)} rule(s), #{length(scenarios)} scenario(s)"
         }}

      {[], advisory} ->
        {true,
         %{
           status:
             "Three Amigos complete: #{length(personas)} persona(s), #{length(rules)} rule(s), #{length(scenarios)} scenario(s)",
           advisory: advisory
         }}

      {gaps, nil} ->
        {false, %{reason: format_gaps(story, gaps)}}

      {gaps, advisory} ->
        {false, %{reason: format_gaps(story, gaps) <> "\n\nAdvisory: " <> advisory}}
    end
  end

  defp build_rules_advisory(rules)
       when length(rules) >= @rule_advisory_threshold and length(rules) < @rule_ceiling do
    "Heads up — this story has #{length(rules)} rules (past the recommended #{@rule_advisory_threshold}). The hard ceiling is #{@rule_ceiling}. Consider whether this story should be split into smaller, more focused ones before adding more rules."
  end

  defp build_rules_advisory(_rules), do: nil

  defp maybe_add_persona_gap(gaps, []),
    do: [
      "No personas linked to this story — call `create_persona` and `link_persona_to_story`."
      | gaps
    ]

  defp maybe_add_persona_gap(gaps, _personas), do: gaps

  defp maybe_add_rules_gap(gaps, []),
    do: ["No rules on this story — call `add_rule` to add the first one." | gaps]

  defp maybe_add_rules_gap(gaps, _rules), do: gaps

  defp maybe_add_rules_ceiling_gap(gaps, rules) when length(rules) >= @rule_ceiling do
    [
      "Too many rules (#{length(rules)} ≥ #{@rule_ceiling}) — `rules < #{@rule_ceiling}` is the readiness ceiling. The story is too big to spec coherently; slice it into smaller stories."
      | gaps
    ]
  end

  defp maybe_add_rules_ceiling_gap(gaps, _rules), do: gaps

  defp maybe_add_uncovered_rules_gap(gaps, [], _scenarios), do: gaps

  defp maybe_add_uncovered_rules_gap(gaps, rules, scenarios) do
    by_rule = Enum.group_by(scenarios, & &1.rule_id)

    uncovered =
      Enum.filter(rules, fn rule ->
        Map.get(by_rule, rule.id, []) == []
      end)

    rule_gaps =
      Enum.map(uncovered, fn rule ->
        "Rule \"#{rule.statement}\" has no scenarios — call `add_scenario` for this rule."
      end)

    rule_gaps ++ gaps
  end

  # Every red card answered, not "more green than red": that rule passed
  # stories whose open questions nothing asked again.
  # See knowledge/requirements_graph/checkers, "Three Amigos".
  defp maybe_add_questions_gap(gaps, scenarios, questions) do
    open = Enum.filter(questions, &(&1.status == :open))

    case open do
      [] ->
        gaps

      open ->
        [
          "#{length(open)} open question(s) on this story: " <>
            Enum.map_join(open, "; ", & &1.text) <>
            ". Three Amigos is not complete while a red card is unanswered — " <>
            "#{length(scenarios)} scenario(s) does not settle them. " <>
            "Answer each with `resolve_question`, or close the ones that turned out " <>
            "to be somebody else's problem."
          | gaps
        ]
    end
  end

  defp format_gaps(story, gaps) do
    title = story.title || "story #{story.number}"
    bullets = Enum.map_join(gaps, "\n", &"- #{&1}")
    "Three Amigos incomplete on \"#{title}\":\n\n#{bullets}"
  end
end
