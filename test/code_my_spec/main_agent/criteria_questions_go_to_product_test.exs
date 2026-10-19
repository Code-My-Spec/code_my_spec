defmodule CodeMySpec.Agents.Main.CriteriaQuestionsGoToProductTest do
  @moduledoc """
  8c91d5bc. A coder's question about criterion 944 sat in the customer's queue.

  (c) A question the asker marks `about: "criteria"` — a story's acceptance
  criteria or its spec — goes to the project's product agent, which owns them.
  (b) Main can still answer a teammate's question that sits with the user.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import CodeMySpec.IssuesFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Agents.Main, as: MainAgent
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Notifications
  alias CodeMySpec.TaskOwner
  alias CodeMySpecTest.AgentPresence
  alias CodeMySpecTest.RecordingAgentTransport

  setup do
    scope = full_scope_fixture()
    RecordingAgentTransport.listen(scope)

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    scope = %{scope | active_working_copy_id: copy.id}
    coder = agent(scope, copy, :coding)

    {:ok, coder} =
      TaskOwner.add_task(scope, coder, %{status: :active, requirement_name: "story_promoted"})

    %{scope: scope, copy: copy, coder: coder, task: TaskOwner.active_task(coder)}
  end

  defp agent(scope, copy, role) do
    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: role,
        continuous: true,
        status: :running,
        working_copy: "/tmp/criteria-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    AgentPresence.present(agent)

    agent
  end

  defp frame(ctx, agent), do: %Frame{assigns: %{current_scope: ctx.scope, agent_id: agent.id}}

  defp text({_status, text}) when is_binary(text), do: text

  defp text(response),
    do: response |> Response.to_protocol() |> Map.fetch!("content") |> Enum.map_join(& &1["text"])

  defp ask(ctx, extra \\ %{}) do
    params =
      Map.merge(
        %{
          task_id: ctx.task.id,
          questions: [%{question: "Revert the fix or rewrite criterion 944?", options: []}]
        },
        extra
      )

    response =
      ToolLibrary.run(
        "ask_question",
        params,
        Map.put(
          frame(ctx, ctx.coder).assigns,
          :scope,
          frame(ctx, ctx.coder).assigns[:current_scope]
        )
      )

    assert match?({:ok, _}, response), text(response)
    [_, id] = Regex.run(~r/Question id: ([a-f0-9-]+)/i, text(response))
    Notifications.get_question_request(id)
  end

  defp released?(ctx) do
    task = Agent |> Repo.get!(ctx.coder.id) |> TaskOwner.find_task(ctx.task.id)
    task.blocker_resolved_at != nil
  end

  describe "(c) a question about criteria" do
    test "goes to the product agent, which is woken for it", ctx do
      product = agent(ctx.scope, ctx.copy, :product)

      request = ask(ctx, %{about: "criteria"})

      assert request.holder == "product_agent"
      product_id = product.id
      assert_receive {:work_turn_requested, ^product_id, _ref, prompt}, 2_000
      assert prompt =~ "answer_notification"
    end

    test "goes to main when no product agent is running", ctx do
      _main = agent(ctx.scope, ctx.copy, :main)
      assert ask(ctx, %{about: "criteria"}).holder == "main_agent"
    end

    test "without `about` goes to main, as before", ctx do
      _main = agent(ctx.scope, ctx.copy, :main)
      _product = agent(ctx.scope, ctx.copy, :product)
      assert ask(ctx).holder == "main_agent"
    end

    test "product answers it as the owner of the criteria, and the task is released", ctx do
      product = agent(ctx.scope, ctx.copy, :product)
      request = ask(ctx, %{about: "criteria"})

      listing =
        ToolLibrary.run(
          "list_notifications",
          %{},
          Map.put(
            frame(ctx, product).assigns,
            :scope,
            frame(ctx, product).assigns[:current_scope]
          )
        )

      assert text(listing) =~ "Needs your attention"
      assert text(listing) =~ request.id

      response =
        ToolLibrary.run(
          "answer_notification",
          %{notification_id: request.id, answer: "Criterion 944 is rewritten; keep the fix."},
          Map.put(
            frame(ctx, product).assigns,
            :scope,
            frame(ctx, product).assigns[:current_scope]
          )
        )

      assert match?({:ok, _}, response), text(response)
      answered = Notifications.get_question_request(request.id)
      assert answered.status == "answered"
      assert answered.answered_by == "product_agent"
      assert released?(ctx)
    end

    # Metric Flow's product saw only "A question for you" through run_script and
    # could not answer QA's story 56 question (2026-10-15).
    test "the scripted listing carries the question itself", ctx do
      product = agent(ctx.scope, ctx.copy, :product)
      request = ask(ctx, %{about: "criteria"})

      frame = frame(ctx, product)

      {:ok, rows} =
        ToolLibrary.data(
          "list_notifications",
          %{},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      row = Enum.find(rows, &(&1["id"] == request.id))

      assert row["questions"] == ["Revert the fix or rewrite criterion 944?"]
    end

    test "product with nothing routed to it is told so", ctx do
      product = agent(ctx.scope, ctx.copy, :product)

      listing =
        ToolLibrary.run(
          "list_notifications",
          %{},
          Map.put(
            frame(ctx, product).assigns,
            :scope,
            frame(ctx, product).assigns[:current_scope]
          )
        )

      assert text(listing) =~ "Nothing is waiting on you"
    end

    test "product cannot answer a question that is not its own", ctx do
      _main = agent(ctx.scope, ctx.copy, :main)
      product = agent(ctx.scope, ctx.copy, :product)
      request = ask(ctx)

      response =
        ToolLibrary.run(
          "answer_notification",
          %{notification_id: request.id, answer: "do it"},
          Map.put(
            frame(ctx, product).assigns,
            :scope,
            frame(ctx, product).assigns[:current_scope]
          )
        )

      assert match?({:error, _}, response)
      assert Notifications.get_question_request(request.id).status == "pending"
    end

    test "product carries what answering takes, and is woken by teammates' questions" do
      for tool <- ~w(list_notifications answer_notification escalate_question withdraw_question) do
        assert RoleProfile.carries?(:product, tool), tool
      end

      assert RoleProfile.wakes_on?(:product, :teammate_question)
    end
  end

  describe "(b) main answers a teammate's question held by the user" do
    setup ctx do
      main = agent(ctx.scope, ctx.copy, :main)
      request = ask(ctx)

      {:ok, _} =
        MainAgent.escalate_question(ctx.scope, request.id, "a product call")

      Map.merge(ctx, %{main: main, request: request})
    end

    test "is answered, attributed to main, and its task released", ctx do
      issue = issue_fixture(ctx.scope, %{title: "criterion 944 rewritten by product"})

      response =
        ToolLibrary.run(
          "answer_notification",
          %{
            notification_id: ctx.request.id,
            answer: "Moot: #{issue.title} — keep the fix.",
            basis: "record"
          },
          Map.put(
            frame(ctx, ctx.main).assigns,
            :scope,
            frame(ctx, ctx.main).assigns[:current_scope]
          )
        )

      assert match?({:ok, _}, response), text(response)
      answered = Notifications.get_question_request(ctx.request.id)
      assert answered.status == "answered"
      assert answered.answered_by == "main_agent"
      assert released?(ctx)
    end

    test "an answer that does not stand up leaves the user's question as it was", ctx do
      response =
        ToolLibrary.run(
          "answer_notification",
          %{notification_id: ctx.request.id, answer: "just guess", basis: "record"},
          Map.put(
            frame(ctx, ctx.main).assigns,
            :scope,
            frame(ctx, ctx.main).assigns[:current_scope]
          )
        )

      assert match?({:error, _}, response)
      still = Notifications.get_question_request(ctx.request.id)
      assert still.status == "pending"
      assert still.escalation_reason == "a product call"
    end
  end
end
