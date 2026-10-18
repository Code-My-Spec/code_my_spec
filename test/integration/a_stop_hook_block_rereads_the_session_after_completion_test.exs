defmodule CodeMySpec.Integration.AStopHookBlockRereadsTheSessionAfterCompletionTest do
  @moduledoc """
  cd296681: `Hooks.Stop.decide/2` fetches `session` once, before
  `TaskEvaluator` runs. `{:ok, :valid}` from evaluation means the active task
  was validly closed -- true whether or not the recorded verdict itself
  passed -- and the block path that follows when the loop is still running
  (more work available) used that same pre-evaluation struct for both
  `Work.actionable/3` and `Menu.render/4`. The completion never reached that
  in-memory struct's own `tasks` association, so the menu reported the task
  `evaluate_task` had just closed as still active, demanding a disposition
  for work the database already showed done -- the contradiction all four
  recurrences on cd296681 describe.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers

  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Requirements
  alias CodeMySpec.Sessions
  alias CodeMySpec.ToolLibrary
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "a task the stop hook just completed is not reported back as still open" do
    %{
      scope: scope,
      frame: frame,
      session_id: session_id,
      external_session_id: external_session_id,
      req1: req1,
      tmp_dir: tmp_dir
    } = setup_workflow_scenario()

    Requirements.recompute(scope)

    session = Sessions.get_session(scope, session_id)
    {:ok, _session} = Sessions.update_session(scope, session, %{continuous: true})

    resp =
      ToolLibrary.run(
        "start_task",
        Map.put(req1, :session_id, session_id),
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    assert match?({:ok, _}, resp)

    active = Sessions.get_session(scope, session_id)
    task = Enum.find(active.tasks, &(&1.status == :active))
    assert task, "start_task did not leave an active task to complete"
    task_id = task.id

    File.mkdir_p!(Path.join(tmp_dir, ".code_my_spec/architecture"))

    File.write!(
      Path.join(tmp_dir, ".code_my_spec/architecture/decisions.md"),
      "# Decisions\n"
    )

    stop_response =
      scope
      |> Stop.decide(%{"session_id" => external_session_id})
      |> Jason.encode!()
      |> Jason.decode!()

    assert stop_response["decision"] == "block",
           "with continuous mode on and more work available, the stop hook " <>
             "should block to keep the loop going rather than allow the stop"

    reason = stop_response["reason"]

    refute reason =~ "Disposition this active task",
           """
           the stop hook's own follow-up still demands disposition of a task it
           just closed:

               #{reason}
           """

    refute reason =~ task_id,
           "the just-completed task's id must not appear in the follow-up directive"

    completed = Sessions.get_session(scope, session_id)
    closed_task = Enum.find(completed.tasks, &(&1.id == task_id))
    assert closed_task.status == :completed
  end
end
