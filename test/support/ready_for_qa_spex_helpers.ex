defmodule CodeMySpecSpex.ReadyForQaHelpers do
  @moduledoc """
  The ready-for-QA gate, story 983's criteria 1774–1779 (John, 2026-10-02):
  completing `ready_for_qa` certifies the copy like a promotion does and stamps
  the commit; the graph reads the stamp.

  Built on `CodeMySpecSpex.PromotionHelpers` — a real checkout and a worktree on
  a story branch — because certifying reads a real tree and a real HEAD.
  """

  alias Anubis.Server.Frame
  alias CodeMySpec.AgentTasks.FixBddSpecs
  alias CodeMySpec.AgentTasks.ReadyForQa
  alias CodeMySpec.McpServers.Requirements.Tools.ShowStoryRequirements
  alias CodeMySpec.McpServers.Stories.Tools.AddCriterion
  alias CodeMySpec.McpServers.Stories.Tools.RetireCriterion
  alias CodeMySpec.McpServers.Stories.Tools.SetActiveStory
  alias CodeMySpec.McpServers.Tasks.Tools.EvaluateTask
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.Fixtures

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  @doc """
  A coding agent on the copy, holding an active `ready_for_qa` task on `story` —
  or, with `legacy?: true`, a task held on the retired `bdd_specs_passing`, as
  agents held them when it was renamed (`FixBddSpecs` delegates; the evaluator
  maps the name).

  Placed on the agent's row rather than claimed through `start_task`: these
  criteria are about completing the task, which `evaluate_task` does without
  consulting prerequisites, and the satisfied-chain fixtures build on the
  in-memory environment while certifying reads a real checkout (a follow-up).
  """
  def a_held_ready_for_qa_task(context, story, opts \\ []) do
    {requirement, module} =
      if Keyword.get(opts, :legacy?, false),
        do: {"bdd_specs_passing", FixBddSpecs},
        else: {"ready_for_qa", ReadyForQa}

    coder = Fixtures.running_agent(context.scope, role: "coding")

    {coder, task} =
      Fixtures.agent_task_fixture(context.scope, coder,
        requirement_name: requirement,
        session_type: module,
        story_id: story.id
      )

    Map.merge(context, %{coder: coder, task_id: task.id})
  end

  @doc """
  Complete the held task through `evaluate_task`, as the agent does — the tool's
  held-task lookup, its dispatch to the task's module, and the module's answer.
  Answers `{error?, text}`.
  """
  def complete_ready_for_qa(context) do
    frame = %Frame{assigns: %{current_scope: context.scope, agent_id: context.coder.id}}
    {:reply, response, _frame} = EvaluateTask.execute(%{task_id: context.task_id}, frame)
    {response.isError == true, response_text(response)}
  end

  @doc "The commit the story is stamped ready for QA at, or nil."
  def qa_stamp(context, story), do: Stories.get_story(context.scope, story.id).qa_ready_commit

  @doc "What `show_story_requirements` says about the story."
  def story_requirements(context, story) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      ShowStoryRequirements.execute(%{story: to_string(story.number)}, frame)

    response_text(response)
  end

  @doc "Whether `requirement` is ticked in a `show_story_requirements` body."
  def satisfied?(body, requirement), do: body =~ ~r/\[x\]\s+\*\*#{requirement}\*\*/

  @doc "Add a criterion to the story through `add_criterion`, as product would."
  def add_criterion(context, story, text) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      AddCriterion.execute(%{story_number: story.number, description: text}, frame)

    response
  end

  @doc "Bind the copy's team to `story` through `set_active_story`, as a team member would."
  def set_active_story(context, story) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      SetActiveStory.execute(%{story_number: story.number}, frame)

    response
  end

  @doc "Retire a criterion through `retire_criterion`, as product would."
  def retire_criterion(context, criterion) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    {:reply, response, _frame} =
      RetireCriterion.execute(%{criterion_number: criterion.number}, frame)

    response
  end
end
