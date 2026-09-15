defmodule CodeMySpecWeb.HarnessCheckoutStateTest do
  @moduledoc """
  What a harness reports about its checkout, from the wire to the row to the
  gate: whether its application is answering.

  The bug this exists to stop, and it is the reason this file is here rather
  than an assertion tucked into a join test: `code_on_running_copy` shipped
  reading a `working_copies` column while nothing anywhere wrote it. The
  gate was correct, the columns were correct, the migration was correct, and
  every story on every non-main checkout was blocked by a fact no agent could
  supply and no code produced — 7 such checkouts on this project, 1 on Broken
  Oaths, within minutes of the deploy.

  Nothing caught it because consumer and producer were tested apart. Both halves
  passed their own tests. So this one runs the whole path: the harness's message
  arrives, the row changes, and the gate reads what the row says.

  ## The git half is gone, and that is the stronger version of the same lesson

  It used to cover `git_state` too — `ahead`/`behind`/`dirty`, wire to row to
  gate. Those columns have been removed. Nothing decided on them: the gate
  answers from the story's own `promoted_version` stamp, and `promote` measures
  git by running it. They were a second, staler copy of something we can always
  ask for, and hashing them into every story's fingerprint made one keystroke
  reconsider every story in the project.

  A column with a writer and no reader is the same defect as one with a reader
  and no writer, and it is quieter: nothing is blocked, it just costs. What
  remains here is `preview_status`, which has both.
  """

  # Not async: the channel takes the project's advisory lock on join.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.StoriesFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.AgentTasks.PromoteWork
  alias CodeMySpec.Promotion
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    scope = full_scope_fixture()

    {:ok, _reply, socket} =
      UserSocket
      |> socket("harness-checkout-state", %{scope: scope})
      |> subscribe_and_join(
        HarnessProjectChannel,
        "harness_project:#{scope.active_project_id}",
        %{
          "label" => "the harness at /workspace/app",
          "harness_id" => scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(scope).id}
        }
      )

    # A *separate* running copy. The join above makes this scope's checkout the
    # project's first with a root, and `report_root/2` designates that one —
    # which would send every case below down the "working on the running copy"
    # branch and assert nothing about what was reported.
    {:ok, running} =
      WorkingCopies.issue(scope, nil,
        label: "the checkout the app runs from",
        device: device_fixture(scope)
      )

    {:ok, _} = WorkingCopies.designate_main(scope, running.id)

    %{scope: scope, socket: socket, running: running}
  end

  defp copy(scope) do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    copy
  end

  # What a *successful* promotion leaves behind: the branch merged into the
  # running copy, this worktree where it was. It used to read as "its work is
  # not on the checkout the application runs from ... Call `promote`" and cost
  # twenty minutes on 2026-09-12, with the running copy's HEAD literally the
  # promotion's own merge commit.
  #
  # Issue cf06b908 named the defect: an unrelated push landing on main after
  # this checkout last synced flipped `commits_behind_main` up and un-satisfied
  # a story whose own commit never moved. The stamp is what settles it, and with
  # the columns gone there is no longer anything for a later push to flip.
  test "a promoted story reads as already across, with nothing to remedy",
       %{scope: scope} do
    story =
      story_fixture(scope, %{
        title: "a story whose work already went across",
        promoted_version: "2.0.11"
      })

    assert {true, _details} = Promotion.running_copy_check(scope, story),
           "a story already stamped promoted was un-satisfied by something its " <>
             "own code reaching main does not depend on"

    {:ok, prompt} = PromoteWork.command(scope, %{story_id: story.id})

    assert prompt =~ ~r/already on the running dev\s+copy/,
           "a promoted story should read as done rather than as something to " <>
             "remedy. Got: " <> prompt

    refute prompt =~ ~r/Call `promote`/,
           "The prompt still tells the agent to promote. Promotion merges this " <>
             "branch into the running copy; there is nothing left to bring across."
  end

  describe "whether the application is answering" do
    defp report_preview(socket, status), do: push(socket, "preview_status", %{"status" => status})

    test "a reported status reaches the row", %{scope: scope, socket: socket} do
      assert copy(scope).preview_status == nil,
             "the premise failed: this copy already has a measurement"

      ref = report_preview(socket, "serving")
      assert_reply(ref, :ok)

      recorded = copy(scope)

      assert recorded.preview_status == "serving"
      assert recorded.preview_checked_at
    end

    # The gate's own half. `code_on_running_copy` proved the code was on the
    # running copy and said nothing about whether anything served it, so QA was
    # sent to a checkout whose app was down and met a connection refused.
    test "and the gate then refuses a running copy that is down", %{scope: scope} do
      running = WorkingCopies.main(scope)
      {:ok, _} = WorkingCopies.record_preview_status(running, "down")

      story = story_fixture(scope, %{promoted_version: "2.0.11"})

      assert {false, %{preview_status: "down"}} = Promotion.running_copy_check(scope, story)
    end

    # A 500 is the application answering, which is the thing QA exists to find.
    # Holding the story back would turn a defect into a gate nobody is looking
    # at.
    test "an application returning errors is QA's to find", %{scope: scope} do
      running = WorkingCopies.main(scope)
      {:ok, _} = WorkingCopies.record_preview_status(running, "erroring")

      story = story_fixture(scope, %{promoted_version: "2.0.11"})

      assert {true, _} = Promotion.running_copy_check(scope, story)
    end

    test "a status the handler does not recognise changes nothing", %{
      scope: scope,
      socket: socket
    } do
      ref = report_preview(socket, "probably fine")
      assert_reply(ref, :error, _)

      assert copy(scope).preview_status == nil,
             "a report the handler could not read still moved the row, so the gate " <>
               "would judge a checkout on a measurement that never happened"
    end
  end
end
