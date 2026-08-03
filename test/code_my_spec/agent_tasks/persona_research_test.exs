defmodule CodeMySpec.AgentTasks.PersonaResearchTest do
  @moduledoc """
  Whether the persona research prompt says which persona needs research.

  It used to say "produce one persona" and stop there. An agent arriving
  without conversation history had to call `list_personas`, work out which one
  was unresearched, and hope — a discovery step the harness could have done
  for it. Observed when `personas_complete` clamped minutes after a Three
  Amigos session created "Per-Story QA Agent": the prompt never named it.

  The gaps come from `PersonasChecker`, the thing about to grade the task, so
  the prompt cannot drift from the bar it is judged against.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.PersonaResearch
  alias CodeMySpec.Personas

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "command/2" do
    test "names the persona whose artifacts are missing", %{scope: scope} do
      {:ok, persona} =
        Personas.create_persona(scope, %{
          name: "Per-Story QA Agent",
          slug: "per-story-qa-agent",
          type: :proto
        })

      assert {:ok, prompt} = PersonaResearch.command(scope, %{})

      assert prompt =~ persona.slug,
             """
             The agent should not have to call `list_personas` and infer which
             persona is unresearched — the checker already knows.

             #{prompt}
             """

      assert prompt =~ "Outstanding"
    end

    test "says so when the project has no personas at all", %{scope: scope} do
      assert {:ok, prompt} = PersonaResearch.command(scope, %{})

      assert prompt =~ "No personas on this project",
             """
             Zero personas is a different starting point from one with missing
             artifacts, and the agent should be told which it is rather than
             calling `list_personas` to find out.

             #{prompt}
             """
    end

    test "renders without a project bound", %{scope: _scope} do
      scope = user_scope_fixture()

      assert {:ok, prompt} = PersonaResearch.command(scope, %{})

      assert prompt =~ "Persona Research",
             "the prompt still has to render — the missing-project case is " <>
               "already covered under Prereqs"
    end
  end
end
