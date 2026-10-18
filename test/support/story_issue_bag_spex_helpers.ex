defmodule CodeMySpecSpex.StoryIssueBagHelpers do
  @moduledoc "Agent-facing actions for the story issue submission scenarios."

  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.Fixtures.StoryIssueBag
  alias CodeMySpecSpex.PromotionHelpers
  alias CodeMySpecSpex.StoryBoundHelpers
  alias CodeMySpecSpex.StorySliceHelpers

  def team(context), do: StoryBoundHelpers.team_on_a_story(context)

  def issue(context, key, attrs \\ %{}) do
    defaults = %{
      title: "Story issue #{key}",
      status: :accepted,
      severity: :high,
      story_id: context.story.id,
      scope: :app
    }

    Map.put(context, key, Fixtures.issue_fixture(context.scope, Map.merge(defaults, attrs)))
  end

  def other_story_issue(context, key) do
    other = Fixtures.authored_story(context.scope, "Unrelated story")
    issue(context, key, %{story_id: other.id})
  end

  def finding(context, key, status) do
    text =
      call(
        context,
        "create_issue",
        %{
          title: "New finding",
          description: "A newly observed behavior",
          scope: "app",
          severity: if(status == :dismissed, do: "low", else: "high"),
          story_number: context.story.number
        },
        :qa
      )

    [_, id] = Regex.run(~r/ID: ([a-f0-9-]+)/, text)

    case status do
      :dismissed ->
        call(context, "dismiss_issue", %{issue_id: id, reason: "Nonblocking observation"}, :qa)

      :accepted ->
        call(context, "accept_issue", %{issue_id: id, category: "bug"}, :qa)
    end

    Map.put(context, key, %{id: id})
  end

  def promotable(context) do
    context = PromotionHelpers.a_promotable_project(context)
    story = PromotionHelpers.a_promotable_story(context, qa: :not_passed)
    context = context |> Map.put(:story, story) |> StorySliceHelpers.staff()
    context = StorySliceHelpers.activate(context)
    coding = Enum.find(context.team, &(&1.role == :coding))
    qa = Enum.find(context.team, &(&1.role == :qa))
    context = Map.merge(context, %{coding: coding, qa: qa, agent_id: coding.id})
    context = PromotionHelpers.with_work_on_the_copy(context)
    # A main-only change makes the promotion a merge requiring fresh gate
    # evidence; the candidate's own green runs cannot certify that new tree.
    PromotionHelpers.commit_work(
      context,
      context.running_root,
      "lib/broken_oaths/diplomacy/treaty.ex",
      PromotionHelpers.treaty()
    )

    context = context |> issue(:a) |> issue(:b)
    head = PromotionHelpers.head_of(context, context.agent_root)
    context = context |> submit(:a, revision: head) |> submit(:b, revision: head)
    StoryIssueBag.certify(context.scope, story.id, head)
    context |> review() |> qa_result("pass") |> PromotionHelpers.analyzers_are_current()
  end

  def revision, do: String.duplicate("a", 40)

  def evidence,
    do: "Fixed the missing delivery. Files: lib/example.ex. Verified: mix test passes."

  def submit(context, key, opts \\ []) do
    call(
      context,
      "submit_story_issue",
      %{
        issue_id: Map.fetch!(context, key).id,
        revision: Keyword.get(opts, :revision, revision()),
        evidence: Keyword.get(opts, :evidence, evidence())
      },
      :coding
    )

    context
  end

  def next(context, role), do: call(context, "get_next_requirement", %{}, role)

  def requirements(context),
    do: call(context, "list_requirements", %{limit: 1000}, :coding)

  def issue_text(context, key),
    do: call(context, "get_issue", %{issue_id: Map.fetch!(context, key).id}, :coding)

  def start_fix(context, key) do
    call(
      context,
      StartTask,
      %{
        requirement_name: "submitted",
        entity_type: "issue",
        entity_id: Map.fetch!(context, key).id
      },
      :coding
    )
  end

  def review(context, key \\ :review) do
    task_id = StoryIssueBag.review(context.scope, context.story.id)
    Map.put(context, key, task_id)
  end

  def qa_result(context, status, issues \\ [], review_key \\ :review) do
    text =
      call(
        context,
        "submit_qa_result",
        %{
          task_id: Map.fetch!(context, review_key),
          status: status,
          scenarios: [
            %{name: "Story behavior", status: status, observation: "Reviewed the submitted work"}
          ],
          issue_ids: Enum.map(issues, &Map.fetch!(context, &1).id)
        },
        :qa
      )

    Map.put(context, :qa_response, text)
  end

  def history(context),
    do: call(context, "list_qa_attempts", %{story_number: context.story.number}, :qa)

  def qa_requirements(context),
    do:
      call(
        context,
        "list_requirements",
        %{requirement_name: "qa_complete", status: "satisfied"},
        :qa
      )

  def ready(context) do
    StoryIssueBag.certify(context.scope, context.story.id, revision())
    context
  end

  defp call(context, tool, params, role) do
    agent = Map.fetch!(context, role)
    StorySliceHelpers.call(context, tool, params, %{agent_id: agent.id})
  end
end
