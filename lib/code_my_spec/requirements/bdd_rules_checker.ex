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
  alias CodeMySpec.Stories
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

  @doc """
  Whether this story's Three Amigos session has been sealed.

  What `three_amigos_complete` reads. Deliberately a different question from
  `complete?/2`, which asks whether the story *would* seal right now:

    * `complete?` is the bar. `ThreeAmigos.evaluate/2` calls it, and seals on a
      pass — so sealing cannot happen while a red card is open.
    * `sealed?` is the record. Once set it stays set, and a question raised
      afterwards does not unset it.

  Recomputing `complete?` here is what the requirement used to do, and it meant
  a red card added to a story that shipped months ago quietly un-shipped it —
  the requirement went false, the story left the graph, and nothing said why.
  A seal is a statement about a conversation that happened.

  Takes the same three-argument shape as `complete?/3` so the preloaded and
  querying paths agree; there is nothing to preload for a field on the story.
  """
  @spec sealed?(Scope.t(), term(), map()) :: {boolean(), map()}
  def sealed?(scope, entity, _ctx), do: sealed?(scope, entity)

  @spec sealed?(Scope.t(), term()) :: {boolean(), map()}
  def sealed?(_scope, %Story{three_amigos_sealed: true}),
    do: {true, %{status: "Three Amigos sealed"}}

  def sealed?(scope, %Story{} = story) do
    # Re-read before concluding "not sealed", because the struct in hand may
    # predate the seal. `ThreeAmigos.evaluate/2` seals mid-request and the
    # response then re-checks this requirement from a story loaded before it —
    # which reported "ready to seal but has not been sealed" about a story that
    # had just been sealed one call earlier.
    #
    # Only on the negative path, so a sealed story costs nothing and an unsealed
    # one costs a single read that decides whether it is really unsealed. The
    # positive clause above already answered from the struct.
    case Stories.get_story(scope, story.id) do
      %Story{three_amigos_sealed: true} ->
        {true, %{status: "Three Amigos sealed"}}

      _ ->
        unsealed_reason(scope, story)
    end
  end

  def sealed?(_scope, _entity),
    do: {false, %{reason: "No active scope or invalid story entity — cannot check Three Amigos."}}

  defp unsealed_reason(scope, story) do
    # The bar it has not cleared, because "not sealed" on its own tells nobody
    # what to do about it.
    case complete?(scope, story) do
      {true, _meta} ->
        {false,
         %{
           reason:
             "Three Amigos is ready to seal but has not been sealed. Evaluate the " <>
               "three_amigos_complete task to seal it."
         }}

      {false, meta} ->
        {false, meta}
    end
  end

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

  # Every red card answered, not more green than red.
  #
  # It used to pass when `scenarios > open questions` — Wynne's Example Mapping
  # signal, which is a good read on whether a story is *ready to estimate* and a
  # bad one for whether the conversation is finished. A story with five
  # scenarios and three open questions satisfied it, and those three questions
  # were then never asked again by anything. Measured on this project before
  # changing it: 50 released stories carried unanswered red cards while
  # reporting Three Amigos complete.
  #
  # A red card is a thing nobody knew the answer to. Building on top of one is
  # the failure Example Mapping exists to prevent, so the gate asks for what the
  # practice actually asks for: resolve it, or decide it is out of scope and
  # close it. `scenarios` is still taken so the count can be reported.
  defp maybe_add_questions_gap(gaps, scenarios, questions) do
    open = Enum.filter(questions, &(&1.status == :open))

    case open do
      [] ->
        gaps

      open ->
        [
          "#{length(open)} open question(s) on this story, and Three Amigos is not " <>
            "complete while a red card is unanswered — #{length(scenarios)} scenario(s) " <>
            "does not settle them. Answer each with `resolve_question`, or close the " <>
            "ones that turned out to be somebody else's problem."
          | gaps
        ]
    end
  end

  defp format_gaps(story, gaps) do
    title = story.title || "story #{story.id}"
    bullets = Enum.map_join(gaps, "\n", &"- #{&1}")
    "Three Amigos incomplete on \"#{title}\":\n\n#{bullets}"
  end
end
