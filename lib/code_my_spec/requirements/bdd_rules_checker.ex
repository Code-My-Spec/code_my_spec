defmodule CodeMySpec.Requirements.BddRulesChecker do
  @moduledoc """
  Delegate checker for the `three_amigos_complete` requirement on
  `story_graph`.

  Validates the Three Amigos readiness gate against the active story:

    * ≥1 persona linked via `persona_stories`
    * ≥1 Rule (blue card) on the story
    * `rules < 10` — Example Mapping ceiling: too many rules means the
      story is too big to spec coherently in one session
    * Every Rule has at least one happy-path scenario AND at least one
      failure-path scenario — the BDD coverage discipline

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

  @rule_ceiling 10

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_account_id: account_id} = scope, %Story{id: story_id} = story)
      when not is_nil(account_id) and not is_nil(story_id) do
    personas = Personas.list_personas_for_story(scope, story_id)
    rules = BddRules.list_rules_for_story(scope, story_id)
    criteria = AcceptanceCriteria.list_story_criteria(scope, story_id)
    # Only kind-tagged criteria are Three Amigos scenarios (green cards).
    # Legacy / fixture-default AC without `kind` don't participate in the
    # readiness gate.
    scenarios = Enum.filter(criteria, &(not is_nil(&1.kind)))
    questions = Questions.list_questions_for_story(scope, story_id)

    gaps =
      []
      |> maybe_add_persona_gap(personas)
      |> maybe_add_rules_gap(rules)
      |> maybe_add_rules_ceiling_gap(rules)
      |> maybe_add_per_rule_coverage_gaps(rules, scenarios)
      |> maybe_add_questions_gap(scenarios, questions)

    case gaps do
      [] ->
        {true,
         %{
           status:
             "Three Amigos complete: #{length(personas)} persona(s), #{length(rules)} rule(s), #{length(scenarios)} scenario(s)"
         }}

      gaps ->
        {false, %{reason: format_gaps(story, gaps)}}
    end
  end

  def complete?(_scope, _entity) do
    {false, %{reason: "No active scope or invalid story entity — cannot check Three Amigos."}}
  end

  defp maybe_add_persona_gap(gaps, []),
    do: ["No personas linked to this story — call `add_persona` and `link_persona_to_story`." | gaps]

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

  defp maybe_add_per_rule_coverage_gaps(gaps, [], _scenarios), do: gaps

  defp maybe_add_per_rule_coverage_gaps(gaps, rules, scenarios) do
    by_rule = Enum.group_by(scenarios, & &1.rule_id)

    coverage_gaps =
      rules
      |> Enum.flat_map(fn rule ->
        scenarios = Map.get(by_rule, rule.id, [])
        kinds = scenarios |> Enum.map(& &1.kind) |> MapSet.new()

        missing_kinds =
          [:happy_path, :failure_path]
          |> Enum.reject(&MapSet.member?(kinds, &1))

        Enum.map(missing_kinds, fn kind ->
          kind_label = kind |> Atom.to_string() |> String.replace("_", "-")

          "Rule \"#{rule.statement}\" is missing a #{kind_label} scenario — call `add_scenario` with `kind: #{kind}` for this rule."
        end)
      end)

    coverage_gaps ++ gaps
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
