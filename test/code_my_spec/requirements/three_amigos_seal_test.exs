defmodule CodeMySpec.Requirements.ThreeAmigosSealTest do
  @moduledoc """
  A Three Amigos session is sealed once, and only with every red card answered.

  Two rules, and they depend on each other.

  **Every red card answered.** The gate used to pass on `scenarios > open
  questions` — Wynne's Example Mapping signal, which reads whether a story is
  ready to *estimate* and says nothing about whether the conversation finished.
  A story with five scenarios and three open questions satisfied it, and nothing
  ever asked those three again. Measured 2026-08-28: 50 released stories on this
  project reported Three Amigos complete while carrying unanswered red cards.

  **Sealed, not recomputed.** Which is what makes the first rule survivable. A
  recomputed requirement means a question raised against a story that shipped
  months ago silently un-ships it — the requirement goes false, the story leaves
  the graph, and nothing says why. A seal is a statement about a conversation
  that happened; a later question is the next conversation.

  The seal is flipped in exactly one place, by a passing check, so "no sealing
  until every rule is met" holds by construction rather than by anyone
  remembering it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.ThreeAmigos
  alias CodeMySpec.Requirements.BddRulesChecker
  alias CodeMySpec.Stories
  alias CodeMySpec.Users.Scope

  setup do
    user = user_fixture()
    account = account_fixture(%{name: "Seal #{System.unique_integer([:positive])}"})

    scope = %Scope{
      user: user,
      user_id: user.id,
      active_account: account,
      active_account_id: account.id
    }

    project = project_fixture(scope)
    scope = %Scope{scope | active_project: project, active_project_id: project.id}

    {:ok, scope: scope, story: story_fixture(scope)}
  end

  defp task_for(story), do: %{entity_type: :story, entity_id: to_string(story.id)}

  defp reload(scope, story), do: Stories.get_story(scope, story.id)

  describe "an unfinished story" do
    test "does not seal, and says what is missing", %{scope: scope, story: story} do
      assert {:ok, :invalid, feedback} = ThreeAmigos.evaluate(scope, task_for(story))

      refute reload(scope, story).three_amigos_sealed,
             "a story with no persona, rules or scenarios was sealed. Sealing is the " <>
               "one thing that must require every rule to hold — there is no other " <>
               "door to `three_amigos_complete`."

      assert is_binary(feedback)
    end
  end

  describe "red cards" do
    # Driven through `complete?/3`'s preloaded shape rather than by writing four
    # tables, because the rule under test is entirely about what those four
    # collections mean together. The querying path lands on the same function,
    # which is why that arity exists.
    defp ctx(story, opts) do
      rule = %{id: 1, statement: "Rule one"}

      scenarios =
        for n <- 1..Keyword.get(opts, :scenarios, 2),
            do: %{id: n, kind: "happy_path", rule_id: rule.id}

      questions =
        for n <- 1..Keyword.get(opts, :open_questions, 0)//1,
            do: %{id: n, status: :open}

      %{
        personas_by_story: %{story.id => [%{id: 1}]},
        rules_by_story: %{story.id => [rule]},
        criteria_by_story: %{story.id => scenarios},
        questions_by_story: %{story.id => questions}
      }
    end

    test "one open question blocks it, however many scenarios there are", %{
      scope: scope,
      story: story
    } do
      # Two scenarios against one open question passes the old signal —
      # `scenarios > open questions`. That is the exact shape 50 released
      # stories on this project were sitting in.
      result =
        BddRulesChecker.complete?(scope, story, ctx(story, scenarios: 2, open_questions: 1))

      assert {false, %{reason: reason}} = result,
             "a story with two scenarios and one open question passed. That is " <>
               "Wynne's ready-to-estimate signal, not a finished conversation: the " <>
               "question was never asked again by anything, and the story got built " <>
               "on top of it."

      assert reason =~ "open question", "the reason should name the red card"
    end

    test "five scenarios do not settle three questions either", %{scope: scope, story: story} do
      assert {false, _} =
               BddRulesChecker.complete?(
                 scope,
                 story,
                 ctx(story, scenarios: 5, open_questions: 3)
               )
    end

    test "and with every red card answered it passes", %{scope: scope, story: story} do
      assert {true, _} =
               BddRulesChecker.complete?(
                 scope,
                 story,
                 ctx(story, scenarios: 2, open_questions: 0)
               ),
             "with no open questions the gate still refuses, so the rule is " <>
               "unsatisfiable rather than strict"
    end
  end

  describe "the seal" do
    test "is what the requirement reads, not a recomputed check", %{scope: scope, story: story} do
      {:ok, sealed} = Stories.update_story(scope, story, %{three_amigos_sealed: true})

      assert {true, _} = BddRulesChecker.sealed?(scope, sealed),
             "the requirement recomputed the conversation instead of reading the seal. " <>
               "That is what let a red card raised against a shipped story silently " <>
               "un-ship it."
    end

    test "survives a question raised afterwards", %{scope: scope, story: story} do
      {:ok, sealed} = Stories.update_story(scope, story, %{three_amigos_sealed: true})

      # The story has no rules or scenarios at all, so `complete?` is emphatically
      # false. A sealed story stays sealed regardless: that is the difference
      # between a record and a recomputation, and it is the whole reason the
      # strict red-card rule can be turned on without pulling shipped work back.
      assert {false, _} = BddRulesChecker.complete?(scope, sealed)
      assert {true, _} = BddRulesChecker.sealed?(scope, sealed)
    end

    test "is not granted just because the story could be sealed", %{scope: scope, story: story} do
      # `sealed?` must not quietly answer "well, it would pass" — that would make
      # the latch decorative and put the requirement back to recomputing.
      assert {false, %{reason: reason}} = BddRulesChecker.sealed?(scope, story)
      assert is_binary(reason)
      refute reload(scope, story).three_amigos_sealed
    end
  end
end
