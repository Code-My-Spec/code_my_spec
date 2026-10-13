defmodule CodeMySpec.McpServers.Tasks.Tools.AskUserQuestionTest do
  @moduledoc """
  The structured question an agent asks.

  Everything downstream of it was already built — `ChatComponents.question/1`
  renders the options, `collect_answers/2` resolves the choice — so what this
  covers is the way in: that the payload it writes is the shape the renderer
  reads, and that what the caller said survives the trip.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Tasks.Tools.AskUserQuestion
  alias CodeMySpec.Sessions
  alias CodeMySpec.TaskOwner

  setup do
    {:ok, scope: full_scope_fixture()}
  end

  defp frame(scope), do: %Anubis.Server.Frame{assigns: %{current_scope: scope}}

  defp a_question(opts \\ []) do
    %{
      "question" => Keyword.get(opts, :question, "Which visual tone?"),
      "header" => Keyword.get(opts, :header, "Theme"),
      "options" => [
        %{"label" => "Warm parchment", "description" => "A grounded medieval feel."},
        %{"label" => "Cool slate", "description" => "A restrained, tactical feel."}
      ]
    }
  end

  # Straight off the table: this is about what was written, and going through a
  # listing would test the listing's filters as well.
  defp latest(_scope) do
    import Ecto.Query

    CodeMySpec.Notifications.QuestionRequest
    |> order_by([q], desc: q.inserted_at)
    |> limit(1)
    |> CodeMySpec.Repo.one()
  end

  test "the caller's title is what the person sees", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(
        %{questions: [a_question()], title: "Capital vassalization rule"},
        frame(scope)
      )

    refute response.isError

    # It read the title off `frame.assigns`, where it never was — it arrives in
    # the params. Every question the agents asked was headed "Claude has a
    # question" while the agent had written something useful.
    assert latest(scope).title == "Capital vassalization rule"
  end

  test "no title falls back to something rather than nothing", %{scope: scope} do
    {:reply, _response, _} = AskUserQuestion.execute(%{questions: [a_question()]}, frame(scope))

    assert latest(scope).title == "A question for you"
  end

  test "the options survive in the shape the renderer reads", %{scope: scope} do
    {:reply, _response, _} = AskUserQuestion.execute(%{questions: [a_question()]}, frame(scope))

    assert [question] = latest(scope).questions
    assert question["question"] == "Which visual tone?"
    assert question["header"] == "Theme"
    assert question["multiSelect"] == false

    assert [%{"label" => "Warm parchment", "description" => _}, %{"label" => "Cool slate"} | _] =
             question["options"]
  end

  test "one question with no options uses the free-text form", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(
        %{questions: [%{"question" => "Thoughts?", "options" => []}]},
        frame(scope)
      )

    refute response.isError
    assert [%{"question" => "Thoughts?", "options" => []}] = latest(scope).questions
  end

  test "free-text questions must be asked individually", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(
        %{questions: [%{"question" => "Thoughts?", "options" => []}, a_question()]},
        frame(scope)
      )

    assert response.isError
    assert latest(scope) == nil
  end

  # Four is what a person is shown at once. Refused rather than truncated:
  # dropping the fifth silently means the agent waits on an answer to something
  # nobody was ever shown.
  test "more questions than a person is shown is refused", %{scope: scope} do
    {:reply, response, _} =
      AskUserQuestion.execute(%{questions: List.duplicate(a_question(), 5)}, frame(scope))

    assert response.isError
  end

  # e3290d96: a Claude Code session's `task_id` never blocked anything — only
  # the agent path (`create_agent_question_request`) did. John's decision
  # 2026-09-29: a session's `ask_user_question` with `task_id` blocks that
  # session's task, the same as for an agent.
  describe "a session's task_id blocks its task, the same as an agent's" do
    defp active_session_task(scope) do
      external_id = "ext-ask-#{System.unique_integer([:positive])}"
      {:ok, session} = Sessions.find_or_create_session(scope, external_id)
      component = component_fixture(scope)

      task_attrs = %{
        session_type: CodeMySpec.AgentTasks.ComponentCode,
        requirement_name: "implementation_file",
        project_id: scope.active_project_id,
        component_id: component.id,
        component_module_name: component.module_name
      }

      {:ok, session_with_task} = Sessions.prepare_task(scope, session, task_attrs)
      task = Enum.find(session_with_task.tasks, &(&1.status == :prepared))
      {:ok, active_session} = Sessions.activate_task(scope, session_with_task, task.id, nil)
      active_task = Enum.find(active_session.tasks, &(&1.id == task.id))

      {external_id, active_task}
    end

    test "the default (active) task is blocked", %{scope: scope} do
      {external_id, task} = active_session_task(scope)

      {:reply, response, _} =
        AskUserQuestion.execute(
          %{questions: [a_question()], session_id: external_id},
          frame(scope)
        )

      refute response.isError
      assert latest(scope).task_id == task.id

      reloaded = Sessions.get_by_external_id(scope, external_id)
      assert %{status: :blocked, blocker_type: :question} = TaskOwner.find_task(reloaded, task.id)
    end

    test "an explicit task_id is blocked", %{scope: scope} do
      {external_id, task} = active_session_task(scope)

      {:reply, response, _} =
        AskUserQuestion.execute(
          %{questions: [a_question()], session_id: external_id, task_id: task.id},
          frame(scope)
        )

      refute response.isError

      reloaded = Sessions.get_by_external_id(scope, external_id)
      assert %{status: :blocked} = TaskOwner.find_task(reloaded, task.id)
    end

    test "a session_id that resolves to nothing still asks, unblocked", %{scope: scope} do
      {:reply, response, _} =
        AskUserQuestion.execute(
          %{questions: [a_question()], session_id: Ecto.UUID.generate()},
          frame(scope)
        )

      refute response.isError
      assert latest(scope).task_id == nil
    end

    test "no session_id at all still asks, unblocked", %{scope: scope} do
      {:reply, response, _} = AskUserQuestion.execute(%{questions: [a_question()]}, frame(scope))

      refute response.isError
      assert latest(scope).task_id == nil
    end
  end
end
