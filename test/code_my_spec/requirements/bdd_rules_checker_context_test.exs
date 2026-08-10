defmodule CodeMySpec.Requirements.BddRulesCheckerContextTest do
  @moduledoc """
  `complete?/3` reads a preloaded context; `complete?/2` queries. They must
  answer identically.

  The reason the preloaded form exists: `RequirementGraph.compute_story_nodes/3`
  loops every ready story, and the two-argument form asks four separate
  questions per story — personas, rules, criteria, questions. On a project with
  76 ready stories that is 304 queries inside a single graph computation, and
  the graph is recomputed on every stop hook.

  The risk it introduces is drift. Two ways of gathering the same four
  collections can diverge — a filter applied on one path and not the other, a
  story whose personas come from a join table rather than a foreign key — and
  the failure would be silent: an agent told Three Amigos was complete by one
  caller and incomplete by another, for the same story at the same moment.

  So these assert agreement rather than either answer in isolation. Both
  clauses funnel into `evaluate/5`, which is what makes agreement structural,
  and these are what would catch it if that stopped being true.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.Personas
  alias CodeMySpec.Qa
  alias CodeMySpec.Qa.QaAttempt
  alias CodeMySpec.Questions
  alias CodeMySpec.Requirements.{BddRulesChecker, Preloader}
  alias CodeMySpec.Stories

  setup do
    %{scope: full_scope_fixture()}
  end

  defp story!(scope, attrs \\ %{}) do
    {:ok, story} =
      Stories.create_story(
        scope,
        Map.merge(
          %{
            title: "A story #{System.unique_integer([:positive])}",
            description: "for the checker to read"
          },
          attrs
        )
      )

    story
  end

  defp persona!(scope, story) do
    n = System.unique_integer([:positive])

    {:ok, persona} =
      Personas.create_persona(scope, %{
        name: "Sam #{n}",
        slug: "sam-#{n}",
        description: "operator"
      })

    {:ok, _} = Personas.link_persona_to_story(scope, persona.id, story.id)
    persona
  end

  # `complete?/3` only reads what the preloader put in the context, and the
  # preloader only loads stories that are `ready_for_dev`. Marking it is what
  # makes the two paths comparable at all.
  defp ready!(scope, story) do
    {:ok, story} = Stories.update_story(scope, story, %{ready_for_dev: true})
    story
  end

  defp both(scope, story) do
    {BddRulesChecker.complete?(scope, story),
     BddRulesChecker.complete?(scope, story, Preloader.load(scope))}
  end

  describe "the preloaded and querying forms agree" do
    test "on a story with nothing on it", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))

      {queried, preloaded} = both(scope, story)

      assert queried == preloaded
      assert {false, %{reason: reason}} = preloaded
      assert reason =~ "persona"
    end

    test "on a story with a persona but no rules", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))
      persona!(scope, story)

      {queried, preloaded} = both(scope, story)

      assert queried == preloaded
      assert {false, _} = preloaded
    end

    test "on a story carrying rules, scenarios and a persona", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))
      persona!(scope, story)

      {:ok, rule} = BddRules.create_rule(scope, story.id, %{statement: "a rule"})

      {:ok, _} =
        AcceptanceCriteria.create_criterion(scope, story, %{
          name: "the happy path",
          description: "the visitor gets what they came for",
          kind: :happy_path,
          rule_id: rule.id
        })

      {queried, preloaded} = both(scope, story)

      assert queried == preloaded,
             "a preloaded context and four queries must produce the same verdict, or " <>
               "the same story reads complete to one caller and incomplete to another"
    end

    # Questions are the one input with no foreign key to a rule or criterion, so
    # a batch load that grouped them wrongly would show up only here.
    test "on a story with an open question", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))
      persona!(scope, story)
      {:ok, _} = BddRules.create_rule(scope, story.id, %{statement: "a rule"})
      {:ok, _} = Questions.create_question(scope, story.id, %{text: "what about refunds?"})

      {queried, preloaded} = both(scope, story)

      assert queried == preloaded
    end
  end

  # A checker reached with no context at all — `AgentTasks.Evaluator` calls
  # `compute_one/4`, which passes none — must still answer, not crash.
  test "a nil context falls back to querying", %{scope: scope} do
    story = scope |> story!() |> then(&ready!(scope, &1))

    assert BddRulesChecker.complete?(scope, story, nil) == BddRulesChecker.complete?(scope, story)
  end

  # `qa_complete`, the second delegate converted. Same property, and the one
  # that has an ordering to get wrong: the context keeps only the newest attempt
  # per story, so a stale earlier pass must not be what either path reads.
  describe "Qa.complete_check agrees across both forms" do
    defp both_qa(scope, story) do
      {Qa.complete_check(scope, story), Qa.complete_check(scope, story, Preloader.load(scope))}
    end

    test "with no attempt at all", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))

      {queried, preloaded} = both_qa(scope, story)

      assert queried == preloaded
      assert {false, _} = preloaded
    end

    test "with a passing attempt", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))
      attempt!(scope, story, :pass)

      {queried, preloaded} = both_qa(scope, story)

      assert queried == preloaded
      assert {true, _} = preloaded
    end

    # The ordering case. An older pass followed by a newer fail is not a pass,
    # and a context that kept the wrong attempt per story would say it was.
    test "with a failing attempt after a passing one", %{scope: scope} do
      story = scope |> story!() |> then(&ready!(scope, &1))
      attempt!(scope, story, :pass)
      attempt!(scope, story, :fail)

      {queried, preloaded} = both_qa(scope, story)

      assert queried == preloaded,
             "the context keeps one attempt per story — if it kept the oldest, a story " <>
               "whose latest QA failed would report complete"

      assert {false, _} = preloaded
    end
  end

  # Built through `QaAttempt.changeset/2` rather than `Qa.submit_qa_result/2`,
  # which resolves the story from a task and would need a session and an active
  # task to exist. The changeset still applies — `scenarios` is a required
  # non-empty embed — so these are real attempts, just not submitted ones. What
  # is under test is which attempt each path reads, not how one is recorded.
  defp attempt!(_scope, story, status) do
    %QaAttempt{}
    |> QaAttempt.changeset(%{
      story_id: story.id,
      status: status,
      agent_id: "test",
      submitted_at: DateTime.utc_now(),
      scenarios: [%{name: "the only scenario", status: status, observation: "seen"}]
    })
    |> Repo.insert!()
  end
end
