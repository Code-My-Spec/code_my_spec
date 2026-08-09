defmodule CodeMySpec.Requirements.BddRulesChecker do
  @moduledoc """
  Delegate checker for the `three_amigos_complete` requirement on
  `story_graph`.

  Validates the Three Amigos readiness gate against the active story:

    * ≥1 persona linked via `persona_stories`
    * ≥1 Rule (blue card) on the story
    * `rules < 15` — Example Mapping hard ceiling: too many rules means
      the story is too big to spec coherently in one session. Raised
      from 10 once real infrastructure stories (e.g. requirement-graph
      semantics) showed legitimate complexity past 10 that doesn't
      split coherently. Past 10 rules emits a non-blocking advisory
      ("consider whether this story should be split") so the heuristic
      still nudges without trapping legitimately big stories.
    * Every Rule has at least one scenario of any kind — agents must not
      fabricate failure-path examples to satisfy a coverage gate when
      the failure surface lives at a different layer

  Returns `{boolean(), map()}` per the checker contract (see
  `IssuesChecker`, `PersonasChecker`). Failure reasons are formatted as
  a markdown detail string so the stop-hook feedback (or
  `evaluate_task` response) can direct the next turn surgically.

  Two clauses from the design's full readiness gate are not yet enforced
  here:

    * `scenarios > questions` — pending the `Questions` context
    * Domain-language scenarios — explicitly punted to a future review
      agent (per `rules.md` session note: "Scenario quality is not
      enforced in real-time")
  """

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.Personas
  alias CodeMySpec.Questions
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @rule_ceiling 15
  @rule_advisory_threshold 10

  @doc """
  The same verdict, from a preloaded graph context instead of four queries.

  `RequirementGraph` computes every story in one pass, so the four-query form
  below runs once per story — 304 queries on a 76-story project, inside a graph
  that is recomputed on every stop hook. The context carries all four
  collections grouped by story id, so this reads them instead.

  The gaps are computed by the same functions either way. What is preloaded is
  the input, not the answer.
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
      "No personas linked to this story — call `add_persona` and `link_persona_to_story`." | gaps
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

  defp maybe_add_questions_gap(gaps, scenarios, questions) do
    scenario_count = length(scenarios)
    open_question_count = Enum.count(questions, &(&1.status == :open))

    if open_question_count > 0 and scenario_count <= open_question_count do
      [
        "Story is not ready: #{open_question_count} open question(s) but only #{scenario_count} scenario(s) — scenarios > questions is required (Wynne's Example Mapping signal). Resolve open questions or add more scenarios before completing."
        | gaps
      ]
    else
      gaps
    end
  end

  defp format_gaps(story, gaps) do
    title = story.title || "story #{story.id}"
    bullets = Enum.map_join(gaps, "\n", &"- #{&1}")
    "Three Amigos incomplete on \"#{title}\":\n\n#{bullets}"
  end
end
