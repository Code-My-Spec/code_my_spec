defmodule CodeMySpec.TaskOwner.AQueuedPromotionDoesNotHoldTheOnlyTaskSlotTest do
  @moduledoc """
  A promote task waits on the queue, not on the agent: `promote` only enqueues,
  and the task stays open until its batch lands. While main was red a batch
  could not land, so the task could not close and the agent stayed parked
  holding work it could take no action on, unable to claim the issue that had
  been deliberately bound to its copy (issue e515bff3, story 1091).

  The fix must not be to close or cancel the promote task early: criterion 2017
  requires it to stay open until the batch lands or is ejected, and cancelling
  it would also lose the landing's outcome. So the task keeps its place in the
  list, and the agent may still claim work that is waiting on machinery rather
  than on the agent.

  The signal is the task's own `awaiting_subject_id`, written by
  `TaskOwner.await_promotion/3` from the MCP `promote` tool once the queue
  answers `:queued`. It is deliberately *not* a read of the queue:
  `TaskOwner` sits below `PromotionQueue` in the boundary graph, so asking the
  queue from here would close `Qa -> TaskOwner -> PromotionQueue -> Qa`, and no
  enqueuing layer may write the agent's task row for the mirror-image reason
  (issue e23a5547). A `story_promoted` task with no such field is an ordinary
  task and still holds the slot.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IntegrationsFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.PromotionQueue.Repository
  alias CodeMySpec.TaskOwner
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    integration_fixture(scope.user, %{provider: :anthropic})

    {:ok, copy} =
      WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        continuous: false,
        working_copy: "/tmp/queued-promotion-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    scope = %{scope | active_working_copy_id: copy.id}
    %{scope: scope, copy: copy, agent: agent}
  end

  defp enqueue(ctx, story_number, opts) do
    Repository.enqueue(%{
      project_id: ctx.scope.active_project_id,
      working_copy_id: ctx.copy.id,
      commit: "abc1234",
      restart: false,
      subject_type: :story,
      subject_id: Integer.to_string(story_number),
      requested_by_agent_id: Keyword.get(opts, :agent_id)
    })
  end

  # The promotion task open on the agent, and the write the MCP `promote` tool
  # makes once the queue has answered. The tool calls exactly this.
  defp hold_promotion(ctx, story, opts \\ []) do
    {:ok, owner} =
      TaskOwner.add_task(ctx.scope, ctx.agent, %{
        status: :active,
        requirement_name: "story_promoted",
        story_id: story.id
      })

    case Keyword.get(opts, :awaiting) do
      nil ->
        owner

      {type, id} ->
        {:ok, marked} = TaskOwner.await_promotion(owner, type, id)
        marked
    end
  end

  test "the agent claims assigned work while its queued promotion waits", ctx do
    story = story_fixture(ctx.scope)
    {:ok, queued} = enqueue(ctx, story.number, agent_id: ctx.agent.id)
    assert queued.status in [:queued, :gating]

    owner = hold_promotion(ctx, story, awaiting: {"story", to_string(story.number)})
    promote_task = TaskOwner.active_task(owner)
    assert promote_task.requirement_name == "story_promoted"

    assert {:ok, claimed} =
             TaskOwner.add_task(ctx.scope, owner, %{
               status: :active,
               requirement_name: "story_issues_resolved",
               story_id: story.id
             })

    # The claim succeeded, which is the point: the marked promotion no longer
    # refuses it. `active_task/1` still answers the first `:active` task in the
    # list, and that is now the promotion one -- see the note on that below.
    assert Enum.any?(TaskOwner.tasks(claimed), &(&1.requirement_name == "story_issues_resolved"))
    assert promote_task.id in Enum.map(TaskOwner.tasks(claimed), & &1.id)
    assert TaskOwner.find_task(claimed, promote_task.id).status == :active
  end

  test "an activate of prepared work is allowed while the promotion waits", ctx do
    story = story_fixture(ctx.scope)
    {:ok, _queued} = enqueue(ctx, story.number, agent_id: ctx.agent.id)

    owner = hold_promotion(ctx, story, awaiting: {"story", to_string(story.number)})

    {:ok, prepared_owner} =
      TaskOwner.add_task(ctx.scope, owner, %{
        status: :prepared,
        requirement_name: "story_issues_resolved",
        story_id: story.id
      })

    prepared = List.last(TaskOwner.tasks(prepared_owner))

    assert {:ok, activated} = TaskOwner.activate_task(ctx.scope, prepared_owner, prepared.id)
    assert TaskOwner.find_task(activated, prepared.id).status == :active
  end

  test "a promotion task nobody marked still holds the slot", ctx do
    story = story_fixture(ctx.scope)
    {:ok, _someone_elses} = enqueue(ctx, story.number, agent_id: Ecto.UUID.generate())
    owner = hold_promotion(ctx, story)
    held = TaskOwner.active_task(owner).id

    assert {:error, {:active_task_exists, ^held}} =
             TaskOwner.add_task(ctx.scope, owner, %{
               status: :active,
               requirement_name: "story_issues_resolved",
               story_id: story.id
             })
  end

  # The task-row signal says "this task waits on the queue", not "on which
  # candidate": `awaiting_subject_id` names the subject for the record, but
  # `allow_activation/2` deliberately does not compare it. So a task marked for
  # a different story also frees the slot. That is harmless in practice -- the
  # field is only ever written by `promote` for the task the agent is holding --
  # and comparing it here would mean `TaskOwner` re-deriving the queue's subject
  # rules, which is the dependency issue e23a5547 exists to avoid.
  test "a promotion task marked for another story still frees the slot", ctx do
    story = story_fixture(ctx.scope)
    other = story_fixture(ctx.scope)
    {:ok, _queued} = enqueue(ctx, other.number, agent_id: ctx.agent.id)
    owner = hold_promotion(ctx, story, awaiting: {"story", to_string(other.number)})

    assert {:ok, claimed} =
             TaskOwner.add_task(ctx.scope, owner, %{
               status: :active,
               requirement_name: "story_issues_resolved",
               story_id: story.id
             })

    assert Enum.any?(TaskOwner.tasks(claimed), &(&1.requirement_name == "story_issues_resolved"))
  end

  test "an ordinary active task still holds the only slot", ctx do
    story = story_fixture(ctx.scope)

    {:ok, ordinary} =
      TaskOwner.add_task(ctx.scope, ctx.agent, %{
        status: :active,
        requirement_name: "story_issues_resolved",
        story_id: story.id
      })

    held = TaskOwner.active_task(ordinary).id

    assert {:error, {:active_task_exists, ^held}} =
             TaskOwner.add_task(ctx.scope, ordinary, %{
               status: :active,
               requirement_name: "implementation_file",
               story_id: story.id
             })
  end

  test "await_promotion marks only a promotion task", ctx do
    story = story_fixture(ctx.scope)

    {:ok, owner} =
      TaskOwner.add_task(ctx.scope, ctx.agent, %{
        status: :active,
        requirement_name: "story_issues_resolved",
        story_id: story.id
      })

    {:ok, marked} = TaskOwner.await_promotion(owner, "story", to_string(story.number))

    task = TaskOwner.active_task(marked)
    refute task.awaiting_subject_id

    held = task.id

    assert {:error, {:active_task_exists, ^held}} =
             TaskOwner.add_task(ctx.scope, marked, %{
               status: :active,
               requirement_name: "implementation_file",
               story_id: story.id
             })
  end
end
