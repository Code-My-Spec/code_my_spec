defmodule CodeMySpec.Validation.MenuTaskClauseTest do
  @moduledoc """
  What the menu says to an agent that already holds a task.

  On 2026-09-06 the product agent, working `three_amigos_complete` on story 994,
  reached a question it needed answered — whether open borders are bilateral and
  revocable — wrote it into its reply, and stopped. Two things were wrong with
  that stop and the menu named neither: the task was still open, and the
  question had gone somewhere nobody reads.

  The menu's advice on the way out was "call `get_next_requirement`" — correct
  for an agent holding nothing, and exactly wrong for one holding an open task,
  which is how a queue fills with half-finished work.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures
  import CodeMySpec.ComponentsFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.Validation.Menu

  defp task(attrs) do
    struct!(
      %CodeMySpec.Sessions.Task{
        id: "43d57947-9b6b-4309-806c-53a32ae5c65b",
        status: :active,
        requirement_name: "story_issues_resolved",
        story_id: 904
      },
      attrs
    )
  end

  defp agent(tasks), do: %Agent{role: :product, continuous: true, tasks: tasks}

  # An unsatisfied requirement with no unsatisfied prerequisite: actionable, and
  # therefore what the menu sends the agent to when nothing outranks it.
  #
  # A fresh project has one of its own — `personas_complete`, product's, which
  # is the role these tests run as. Nothing has to be planted.
  #
  # This used to insert a `design_file` row straight into the read model,
  # because the menu counted `requirements` rows and the fixtures leave that
  # table empty. The menu counts from the computed graph now, so that row was
  # never read: the graph is computed from components and stories, and an
  # invented row is not in it. The setup would have kept passing while asserting
  # nothing.
  defp scope_with_waiting_requirements do
    scope = full_scope_fixture()
    _component = component_fixture(scope)
    scope
  end

  describe "an open task" do
    setup do
      %{scope: scope_with_waiting_requirements()}
    end

    # The control. If this stops holding, the displacement test below is
    # asserting against an empty queue and means nothing.
    test "requirements are what the menu says when no task is held", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent([]))

      assert menu =~ "`get_next_requirement`"
    end

    test "is the directive, and carries the id evaluate_task needs", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent([task(%{})]))

      assert menu =~ "you have an open task"
      assert menu =~ "`story_issues_resolved` on story 904"
      assert menu =~ "call `evaluate_task`"
      assert menu =~ ~s(task_id "43d57947-9b6b-4309-806c-53a32ae5c65b")
    end

    # The whole point of the clause. Sending an agent to fetch more work while
    # it is holding some is the behaviour this replaced.
    test "displaces get_next_requirement, without dropping it", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent([task(%{})]))

      refute menu =~ "Next: 1 requirement"
      refute menu =~ "`get_next_requirement`"

      # Tallied rather than dropped — a class never mentioned starves
      # invisibly, which is the failure a strict single directive has.
      assert menu =~ "Also live:"
      assert menu =~ "requirement"
    end

    test "a task with no requirement name is still named as open", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent([task(%{requirement_name: nil, story_id: nil})]))

      assert menu =~ "you have an open task"
      assert menu =~ "call `evaluate_task`"
    end
  end

  # What the product agent on the war-epic copy was actually holding on
  # 2026-09-06: six tasks opened in a six-minute burst and left, then the one it
  # was really working on. Nothing closes a task but `evaluate_task`, so they
  # accumulate, and from every other surface an agent that abandons work looks
  # exactly like one that is busy.
  describe "several open tasks" do
    setup do
      %{scope: scope_with_waiting_requirements()}
    end

    defp burst do
      [
        task(%{
          id: "oldest",
          requirement_name: "story_issues_resolved",
          story_id: 904,
          started_at: ~U[2026-09-06 11:26:20.022400Z]
        }),
        task(%{
          id: "middle",
          requirement_name: "bdd_specs_passing",
          story_id: 949,
          started_at: ~U[2026-09-06 11:30:30.545291Z]
        }),
        task(%{
          id: "newest",
          requirement_name: "three_amigos_complete",
          story_id: 994,
          started_at: ~U[2026-09-06 11:58:00.189607Z]
        })
      ]
    end

    # The one it is mid-thought on, not the one it abandoned first. `Enum.find`
    # answers the head of the list, which is the oldest, and would send the
    # agent back to work it had already moved past.
    test "names the newest, not the first", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent(burst()))

      assert menu =~ "`three_amigos_complete` on story 994"
      assert menu =~ ~s(task_id "newest")
      refute menu =~ "story 904"
    end

    test "says how many are open rather than implying one", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent(burst()))

      assert menu =~ "you have 3 open tasks"
      assert menu =~ "The others are still open too"
    end

    # Order in the embed is insertion order, and nothing guarantees the newest
    # is last — a restored agent's rows come back in whatever order the column
    # holds them.
    test "picks the newest whatever order the rows arrive in", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent(Enum.reverse(burst())))

      assert menu =~ ~s(task_id "newest")
    end
  end

  describe "no open task" do
    setup do
      %{scope: scope_with_waiting_requirements()}
    end

    # `prepared` is a task that exists and has not been picked up; `completed`
    # is one already closed. Neither is work in hand, and treating either as one
    # would pin an agent against a row it cannot evaluate.
    test "a prepared or completed task does not count as one", %{scope: scope} do
      owner = agent([task(%{status: :prepared}), task(%{status: :completed})])

      refute Menu.render(scope, true, nil, owner) =~ "you have an open task"
    end

    test "an owner with no tasks reads as it did before the clause existed", %{scope: scope} do
      refute Menu.render(scope, true, nil, agent([])) =~ "open task"
    end

    # Every caller that has not been given an owner — the clause must be inert
    # rather than raising on `nil`.
    test "no owner at all is not an error", %{scope: scope} do
      refute Menu.render(scope, true, nil, nil) =~ "open task"
    end
  end

  describe "the unattended notice" do
    setup do
      %{scope: scope_with_waiting_requirements()}
    end

    # The second half of the incident. A question in the reply reached nobody,
    # and nothing in the refusal said so.
    test "says the conversation is unread and names the tool that is not", %{scope: scope} do
      menu = Menu.render(scope, true, nil, agent([task(%{})]))

      assert menu =~ "Nobody is reading this conversation"
      assert menu =~ "`ask_user_question`"
      assert menu =~ "`send_message`"
    end
  end
end
