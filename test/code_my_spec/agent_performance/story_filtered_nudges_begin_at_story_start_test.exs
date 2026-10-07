defmodule CodeMySpec.AgentPerformance.StoryFilteredNudgesBeginAtStoryStartTest do
  use CodeMySpecSpex.Case, async: false

  alias CodeMySpec.AgentPerformance.Chart
  alias CodeMySpec.AgentPerformance.Interventions
  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "story nudges begin at the first task while unfiltered counts retain earlier messages",
       context do
    {:ok, story} =
      Stories.create_story(context.scope, %{
        title: "Story with a start boundary",
        description: "Earlier conversation messages must not count toward this story."
      })

    {:ok, story} =
      story |> Stories.Story.changeset(%{ready_for_dev: true}) |> Repo.update()

    agent = Fixtures.running_agent(context.scope, role: "coding")
    :ok = Agents.claim_story(context.scope, agent, story.id)
    started_at = DateTime.add(DateTime.utc_now(), -3600, :second)

    Fixtures.agent_task_fixture(context.scope, agent,
      story_id: story.id,
      started_at: started_at
    )

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    add_nudge(conversation, "before start", DateTime.add(started_at, -3600, :second))
    add_nudge(conversation, "at start", started_at)
    add_nudge(conversation, "after start", DateTime.add(started_at, 60, :second))

    filtered = Interventions.for_scope(context.scope, %{story_id: story.id})
    assert Enum.sort(Enum.map(filtered, & &1.reason)) == ["after start", "at start"]

    assert Enum.any?(Interventions.for_scope(context.scope), &(&1.reason == "before start"))
    assert Chart.detail(context.scope, %{story_id: story.id}).nudges == 2

    option = Chart.option(context.scope, %{story_id: story.id})
    nudges = Enum.find(option["series"], &(&1["name"] == "nudges"))
    assert Enum.sum(nudges["data"]) == 2
  end

  defp add_nudge(conversation, text, at) do
    {:ok, message} = Conversations.add_message(conversation, :operator, text, "operator")
    {:ok, _message} = message |> Ecto.Changeset.change(inserted_at: at) |> Repo.update()
  end
end
