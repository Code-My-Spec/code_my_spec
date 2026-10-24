defmodule CodeMySpec.Agents.ACodingAgentCanSayWhichCheckoutItIsOnTest do
  @moduledoc """
  A coding agent can answer "which working copy am I on" itself.

  Issue `37ba3a69`. A coding agent runs inside one checkout of a project that
  may have several, and it kept being asked to name its own — in a brief, in a
  handoff, in a question back to main — with no way to look it up. The refusal
  said `list_working_copies` "belongs to another role", which was true and
  unhelpful: the tool is a read of rows the caller is already scoped to, and
  the caller *is* one of them.

  Both halves are asserted, because a grant that only says "yes" is the easy
  half:

    * the coding role carries it, so an agent can call it at all; and
    * calling it answers with the caller's own copy among the rows — the
      `active_working_copy_id` the connection already resolved — so "which one
      am I" is a lookup rather than a guess.

  It stays read-only. `create_working_copy`, `offboard_working_copy` and
  `set_working_copy_loop` keep staffing off the coder's list: a coder answers
  where it is, it does not make more places to be.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AppInstances
  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.ToolLibrary
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    # Two checkouts, and two machines between them: `issue/3` recognises a root
    # per device, so one device and one root is one row however many times it is
    # issued. `report_root/2` is what gives a row a root -- `issue/3` mints
    # before any root is known -- and it is the same call a joining harness
    # makes, so this is the shape a real agent sees.
    {:ok, elsewhere} =
      WorkingCopies.issue(scope, nil, label: "another", device: device_fixture(scope))

    {:ok, _} =
      WorkingCopies.report_root(elsewhere, CodeMySpec.TempFile.owned_dir("copy_elsewhere"))

    {:ok, mine} =
      WorkingCopies.issue(scope, nil, label: "mine", device: device_fixture(scope))

    root = CodeMySpec.TempFile.owned_dir("copy_mine")
    {:ok, mine} = WorkingCopies.report_root(mine, root)

    {:ok, scope: %{scope | active_working_copy_id: mine.id}, mine: mine, root: root}
  end

  describe "the grant" do
    test "coding carries list_working_copies" do
      assert RoleProfile.carries?(:coding, "list_working_copies"),
             "a coder that cannot say which checkout it is in will guess, and the " <>
               "guess reaches a brief or a promotion"
    end

    test "and still carries no staffing" do
      for tool <- ~w(create_working_copy offboard_working_copy set_working_copy_loop) do
        refute RoleProfile.carries?(:coding, tool),
               "answering where you are is a read; making and looping copies is main's"
      end
    end
  end

  describe "the answer" do
    test "names the caller's own copy, by id and by root", %{
      scope: scope,
      mine: mine,
      root: root
    } do
      {:ok, rows} =
        ToolLibrary.data("list_working_copies", %{}, Map.put(frame(scope).assigns, :scope, scope))

      assert is_list(rows),
             "the answer crosses into Lua as a table, not a string that has to be parsed"

      assert Enum.any?(rows, &(&1["id"] == mine.id)),
             "the copy the connection resolved has to be in its own answer: #{inspect(rows)}"

      assert Enum.any?(rows, &(&1["root"] == root)),
             "and answerable by the root the agent is standing in: #{inspect(rows)}"

      assert Enum.any?(rows, & &1["main"]),
             "this project has a checkout on disk, so one row is the one to build on"

      refute Enum.any?(rows, &(is_nil(&1["root"]) and &1["main"])),
             "the row with no disk behind it is never the destination"
    end

    test "and never another project's checkouts", %{scope: scope, mine: mine} do
      {:ok, other} =
        CodeMySpec.Projects.create_project(scope, %{
          name: "another project #{System.unique_integer([:positive])}"
        })

      other_scope = %{scope | active_project_id: other.id}

      {:ok, theirs} =
        WorkingCopies.issue(other_scope, nil, label: "theirs", device: device_fixture(scope))

      {:ok, _} = WorkingCopies.report_root(theirs, CodeMySpec.TempFile.owned_dir("theirs"))

      {:ok, rows} =
        ToolLibrary.data("list_working_copies", %{}, Map.put(frame(scope).assigns, :scope, scope))

      refute Enum.any?(rows, &(&1["id"] == theirs.id)),
             "another project's checkout in this answer is a wrong answer to 'which one am I'"

      assert Enum.any?(rows, &(&1["id"] == mine.id))
    end

    test "app instance health timestamps cross the Lua boundary as ISO 8601", %{
      scope: scope,
      mine: mine
    } do
      {:ok, instance} = AppInstances.ensure_default(scope, mine)
      {:ok, _instance} = AppInstances.record_status(scope, instance, %{status: "serving"})

      {:ok, rows} =
        ToolLibrary.data("list_working_copies", %{}, Map.put(frame(scope).assigns, :scope, scope))

      row = Enum.find(rows, &(&1["id"] == mine.id))
      [app] = row["app_instances"]

      assert {:ok, _datetime, 0} = DateTime.from_iso8601(app["checked_at"])
    end
  end

  # The frame a tool sees: it reads `current_scope` off the transport's assigns,
  # which is exactly what `Plugs.AgentScope` + `Plugs.DeployKeyOrOAuth` set.
  defp frame(scope) do
    %Anubis.Server.Frame{assigns: %{current_scope: scope}}
  end
end
