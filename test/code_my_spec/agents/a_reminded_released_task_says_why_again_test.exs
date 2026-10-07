defmodule CodeMySpec.Agents.ARemindedReleasedTaskSaysWhyAgainTest do
  @moduledoc """
  Story 1080, criterion 2057: a rung is a rung for every kind.

  `offer_prompt/3` chose its extra text by the subject being a requirement, so a
  released task's *second* offer -- the `:remind` rung of its own ladder -- was
  the first sentence said again. The ladder exists so a notice that was ignored
  says something different next time; for this kind it said nothing more.
  """
  use CodeMySpecSpex.Case, async: false

  alias Anubis.Server.Frame
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Offers
  alias CodeMySpec.Agents.Work
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask
  alias CodeMySpec.Notifications
  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.TaskOwner
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup ctx do
    :ok = Fixtures.install_recording_agent_transport()
    ctx = FullSatisfactionFixtures.apply(ctx)

    {:ok, _} =
      CodeMySpec.WorkingCopies.designate_main(ctx.scope, ctx.scope.active_working_copy_id)

    # An open issue, so triage is real claimable work: the released task below is
    # offered only while the graph still holds something for this agent.
    {:ok, _issue} =
      Issues.create_issue(ctx.scope, %{
        title: "the export button does nothing",
        description: "twice",
        severity: :medium
      })

    :ok = GraphWatcher.settle(ctx.scope)

    product = Fixtures.running_agent(ctx.scope, role: "product", continuous: true)
    frame = %Frame{assigns: %{current_scope: ctx.scope, agent_id: product.id}}
    Map.merge(ctx, %{product: product, frame: frame})
  end

  setup ctx do
    assert {:ok, _} = start_triage(ctx)
    question = ask(ctx.scope, Repo.get!(Agent, ctx.product.id))

    product =
      Agent
      |> Repo.get!(ctx.product.id)
      |> Agent.add_task(%{
        status: :active,
        requirement_name: "personas_complete",
        started_at: DateTime.utc_now()
      })
      |> Repo.update!()

    [blocked] = Enum.filter(product.tasks, &(&1.status == :blocked))
    Map.merge(ctx, %{product: product, question: question, blocked: blocked})
  end

  defp start_triage(ctx),
    do:
      StartTask.execute(
        %{
          requirement_name: "issues_triaged",
          entity_type: "project",
          entity_id: to_string(ctx.scope.active_project_id)
        },
        ctx.frame
      )
      |> started()

  test "the second offer of a released task adds the reminder text", ctx do
    product_id = ctx.product.id
    {:ok, _} = Notifications.answer_question_request(ctx.question.id, %{"Which?" => "A"})

    # The task the question blocked is released; the other one this agent held
    # is finished, so it is idle and the released task is what it is offered.
    {:ok, product} =
      TaskOwner.complete_task(ctx.scope, Repo.get!(Agent, product_id), sibling_id(product_id))

    assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, product, :test)

    first = release_notice(ctx, product_id)
    assert first =~ "Your blocker was released;"
    assert first =~ "resume task #{ctx.blocked.id}"

    [offer] = Offers.list(ctx.scope, agent_id: product_id, kind: :unblocked)

    # The turn took nothing, so its end settles the offer ignored and writes the
    # `:remind` rung -- which the next offer of the same task must render.
    :ok = Offers.settle_turn(Repo.get!(Agent, product_id))
    assert %{ignored: 1} = Offers.standing(product_id)[offer.subject_key]

    # The turn is over, so its reservation is not still standing (a new turn
    # cannot be offered into one), and nothing has to finish first.
    :ok = clear_reservation(ctx, product_id)
    :ok = Fixtures.drain_background_work()

    assert {:ok, _ref} = Work.request_turn_if_runnable(ctx.scope, Repo.get!(Agent, product_id), :test)

    second = release_notice(ctx, product_id)
    assert second =~ "Your blocker was released;"
    assert second =~ "You were told this last turn and did not take it"
    assert second =~ "`reject_offer` with your reason so main can reassign it"
    refute second == first, "the second notice said the first one again, word for word"
  end

  # What a turn reporting itself started would leave behind: no reservation.
  defp started({:reply, response, _}), do: {:ok, response}

  defp clear_reservation(ctx, product_id) do
    agent = Repo.get!(Agent, product_id)

    {:ok, _} =
      AgentsRepository.update_agent(ctx.scope, agent, %{
        work_request_id: nil,
        work_requested_at: nil
      })

    :ok
  end

  defp sibling_id(product_id) do
    Agent |> Repo.get!(product_id) |> Agent.active_task() |> Map.fetch!(:id)
  end

  # The text of the notice actually sent to the agent: the turn prompt is
  # recorded on the conversation before it is dispatched, which is the same
  # string the machine was given and does not depend on who owns the transport.
  defp release_notice(ctx, product_id) do
    :ok = Fixtures.drain_background_work()

    ctx.scope
    |> Fixtures.messages_to_agent(product_id)
    |> Enum.filter(&(&1 =~ "Your blocker was released;"))
    |> List.last()
  end

  defp ask(scope, agent) do
    {:ok, request} =
      Notifications.create_agent_question_request(
        scope,
        agent.id,
        %{
          "title" => "Which approach?",
          "questions" => [%{"question" => "Which?", "options" => [%{"label" => "A"}]}]
        },
        :active
      )

    request
  end
end
