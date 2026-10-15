defmodule CodeMySpec.AgentPerformance.StoryFilteredMessagesBeginAtStoryStartTest do
  use CodeMySpecSpex.Case, async: true

  alias CodeMySpec.AgentPerformance.Chart
  alias CodeMySpec.AgentPerformance.Interventions
  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  test "story messages begin at the first task while unfiltered counts retain earlier messages",
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

    add_message(conversation, "before start", DateTime.add(started_at, -3600, :second))
    add_message(conversation, "at start", started_at)
    add_message(conversation, "after start", DateTime.add(started_at, 60, :second))

    filtered = Interventions.for_scope(context.scope, %{story_id: story.id})
    assert Enum.sort(Enum.map(filtered, & &1.reason)) == ["after start", "at start"]

    assert Enum.any?(Interventions.for_scope(context.scope), &(&1.reason == "before start"))
    assert Chart.detail(context.scope, %{story_id: story.id}).messages == 2

    option = Chart.option(context.scope, %{story_id: story.id})
    messages = Enum.find(option["series"], &(&1["name"] == "messages"))
    assert Enum.sum(messages["data"]) == 2
  end

  test "the chart includes a newly recorded message in its seven-day window", context do
    agent = Fixtures.running_agent(context.scope, role: "coding")

    {:ok, conversation} =
      Conversations.find_or_create_agent_conversation(
        context.scope.active_account_id,
        context.scope.active_project_id,
        agent.id
      )

    {:ok, _message} =
      Conversations.add_message(conversation, :operator, "current message", "operator")

    option = Chart.option(context.scope, %{agent_id: agent.id})
    messages = Enum.find(option["series"], &(&1["name"] == "messages"))

    assert option["bucket_count"] == 168
    assert length(option["categories"]) == 168
    assert Chart.detail(context.scope, %{agent_id: agent.id}).messages == 1
    assert Enum.sum(messages["data"]) == 1
  end

  defp add_message(conversation, text, at) do
    {:ok, message} = Conversations.add_message(conversation, :operator, text, "operator")
    {:ok, _message} = message |> Ecto.Changeset.change(inserted_at: at) |> Repo.update()
  end
end
