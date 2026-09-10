defmodule CodeMySpecWeb.HarnessCheckoutStateTest do
  @moduledoc """
  What a harness reports about its checkout, from the wire to the row to the
  gate: whether its work is on main, and whether its application is answering.

  The bug this exists to stop, and it is the reason this file is here rather
  than an assertion tucked into a join test: `code_on_running_copy` shipped
  reading `working_copies.git_state_at` while nothing anywhere wrote it. The
  gate was correct, the columns were correct, the migration was correct, and
  every story on every non-main checkout was blocked by a fact no agent could
  supply and no code produced — 7 such checkouts on this project, 1 on Broken
  Oaths, within minutes of the deploy.

  Nothing caught it because consumer and producer were tested apart. Both halves
  passed their own tests. So this one runs the whole path: the harness's message
  arrives, the row changes, and the gate reads what the row says.

  `preview_status` is here for the same reason and against the same failure. It
  is the second thing the gate reads that no file records, it travels the same
  way, and one file covering both is what keeps the next column from shipping
  with a reader and no writer.
  """

  # Not async: the channel takes the project's advisory lock on join.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures
  import Phoenix.ChannelTest

  @endpoint CodeMySpecWeb.Endpoint

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
      |> socket("harness-git-state", %{scope: scope})
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

  defp report(socket, state), do: push(socket, "git_state", state)

  defp copy(scope) do
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
    copy
  end

  test "a reported state reaches the row", %{scope: scope, socket: socket} do
    assert copy(scope).git_state_at == nil,
           "the premise failed: this copy already has a measurement"

    ref = report(socket, %{"ahead" => 2, "behind" => 1, "dirty" => true})
    assert_reply(ref, :ok)

    recorded = copy(scope)

    assert recorded.commits_ahead_of_main == 2
    assert recorded.commits_behind_main == 1
    assert recorded.tree_dirty == true

    assert recorded.git_state_at,
           "without a timestamp the gate cannot tell a measurement from a silence, " <>
             "which is the distinction it refuses on"
  end

  # The half that was missing. A gate reading a column nothing writes is a wall,
  # and it is invisible from either side alone.
  test "and the gate then answers from it", %{scope: scope, socket: socket} do
    running = WorkingCopies.main(scope)

    assert running && running.id != scope.active_working_copy_id,
           "the premise failed: this scope is the running copy, which the gate " <>
             "passes for a different reason"

    ref = report(socket, %{"ahead" => 3, "behind" => 0, "dirty" => false})
    assert_reply(ref, :ok)

    assert {false, %{reason: reason}} = Promotion.running_copy_check(scope, %{id: 1})

    assert reason =~ "3 commit(s) here are not on main",
           "the gate did not read what the harness just reported. Got: #{reason}"
  end

  test "a clean, in-sync checkout passes", %{scope: scope, socket: socket} do
    ref = report(socket, %{"ahead" => 0, "behind" => 0, "dirty" => false})
    assert_reply(ref, :ok)

    assert {true, _} = Promotion.running_copy_check(scope, %{id: 1})
  end

  # Untracked files are excluded where this is measured, so `dirty` arriving
  # true means tracked changes. Asserted because the gate's wording promises
  # the agent something it can act on — commit them.
  test "an uncommitted tree is named as such", %{scope: scope, socket: socket} do
    ref = report(socket, %{"ahead" => 0, "behind" => 0, "dirty" => true})
    assert_reply(ref, :ok)

    assert {false, %{reason: reason}} = Promotion.running_copy_check(scope, %{id: 1})
    assert reason =~ "uncommitted changes"
  end

  test "a malformed report changes nothing", %{scope: scope, socket: socket} do
    ref = report(socket, %{"ahead" => "two", "behind" => 1, "dirty" => true})
    assert_reply(ref, :error, _)

    assert copy(scope).git_state_at == nil,
           "a report the handler could not read still moved the row, so the gate " <>
             "would judge a checkout on a measurement that never happened"
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
    test "and the gate then refuses a running copy that is down", %{scope: scope, socket: socket} do
      running = WorkingCopies.main(scope)
      {:ok, _} = WorkingCopies.record_preview_status(running, "down")

      ref = report(socket, %{"ahead" => 0, "behind" => 0, "dirty" => false})
      assert_reply(ref, :ok)

      assert {false, %{preview_status: "down"}} = Promotion.running_copy_check(scope, %{id: 1})
    end

    # A 500 is the application answering, which is the thing QA exists to find.
    # Holding the story back would turn a defect into a gate nobody is looking
    # at.
    test "an application returning errors is QA's to find", %{scope: scope, socket: socket} do
      running = WorkingCopies.main(scope)
      {:ok, _} = WorkingCopies.record_preview_status(running, "erroring")

      ref = report(socket, %{"ahead" => 0, "behind" => 0, "dirty" => false})
      assert_reply(ref, :ok)

      assert {true, _} = Promotion.running_copy_check(scope, %{id: 1})
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
