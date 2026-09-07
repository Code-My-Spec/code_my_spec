defmodule CodeMySpec.AgentTasks.TheBddPromptCarriesTheScenariosTest do
  @moduledoc """
  A prompt that promises the scenarios has to contain them.

  `WriteBddSpecs` tells the agent "Write the spex against the surfaces named in
  the scenario bodies below. They *are* the contract" — and listed criterion
  titles, a suggested file path, and a one-line surface hint derived from the
  body it did not print.

  A coding agent on story 1001 said so exactly: "lists only criterion titles,
  but omits the promised scenario bodies and event/payload contract. Which
  public peace flow should the BDD specs encode?" It could not know. All four
  scenarios were on the rows it had been handed —
  `Given two players are at war / When one player offers peace to the other /
  Then the other player receives a peace offer` — and none of them reached it.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.AcceptanceCriteriaFixtures

  alias CodeMySpec.AgentTasks.WriteBddSpecs
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories

  @scenario """
  Given two players are at war
  When one player offers peace to the other
  Then the other player receives a peace offer\
  """

  defp story_with_criterion(scope, body) do
    component = component_fixture(scope)

    {:ok, story} =
      Stories.create_story(scope, %{
        title: "Mutual Peace Without Settlements",
        description: "As a player, I want to end a war, so that I keep what I hold.",
        ready_for_dev: true,
        component_id: component.id
      })

    scope
    |> criterion_fixture(story, %{description: "A player offers peace to a wartime rival"})
    |> Ecto.Changeset.change(body: body, kind: :happy_path)
    |> Repo.update!()

    %{scope: scope, story: story, component: component}
  end

  defp prompt_for(%{scope: scope, story: story}) do
    {:ok, prompt} =
      WriteBddSpecs.command(scope, %{story_id: story.id, component_id: story.component_id})

    prompt
  end

  setup do
    {:ok, scope: full_scope_fixture()}
  end

  test "the scenario reaches the agent, not just the criterion title", %{scope: scope} do
    prompt = scope |> story_with_criterion(@scenario) |> prompt_for()

    assert prompt =~ "A player offers peace to a wartime rival",
           "the title was never the missing half"

    for line <- String.split(@scenario, "\n") do
      assert prompt =~ line,
             "the prompt promises the scenario bodies and has to contain them: #{line}"
    end
  end

  # The promise and the text are two halves of one thing and drifted apart once.
  # If the sentence goes, this test should be rewritten deliberately rather than
  # quietly passing against a prompt that no longer claims anything.
  test "the prompt still promises what it now carries", %{scope: scope} do
    prompt = scope |> story_with_criterion(@scenario) |> prompt_for()

    assert prompt =~ "scenario bodies below"
  end

  # A criterion with no scenario is a real state — a title somebody has not
  # written up yet — and it has to read as missing rather than as another
  # omission by the prompt.
  test "a criterion with no scenario says so", %{scope: scope} do
    prompt = scope |> story_with_criterion(nil) |> prompt_for()

    assert prompt =~ "No scenario recorded"
  end

  test "an empty scenario reads the same as none at all", %{scope: scope} do
    prompt = scope |> story_with_criterion("   \n  ") |> prompt_for()

    assert prompt =~ "No scenario recorded"
    refute prompt =~ "```gherkin\n\n```"
  end
end
