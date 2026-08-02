defmodule CodeMySpec.Provisioning.SetupOptionsTest do
  @moduledoc """
  Setup options survive the mount that chose them.

  They used to live in the LiveView socket alone: Sam turned object storage
  off, closed the tab, came back, and found it on — then started a run that was
  not the one he configured. Three criteria lean on this (7968, 7982, 7985),
  and each was satisfiable within a single mount and unsatisfiable across two,
  which is a strange shape for a criterion to have.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning

  setup do
    %{scope: full_scope_fixture()}
  end

  describe "a project that has never chosen" do
    test "gets every option", %{scope: scope} do
      assert Provisioning.setup_options(scope.active_project) == Provisioning.available_options()
      refute Provisioning.available_options() == []
    end

    test "the options are derived from the sequence, not listed separately", %{scope: scope} do
      # A step added with a new option must show up as a toggle without anyone
      # remembering to add it in a second place.
      from_sequence =
        CodeMySpec.Provisioning.Sequence.all()
        |> Enum.map(& &1.option)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      assert Enum.sort(Provisioning.setup_options(scope.active_project)) ==
               Enum.sort(from_sequence)
    end
  end

  describe "choosing" do
    test "what was chosen is what comes back", %{scope: scope} do
      assert {:ok, project} = Provisioning.put_setup_options(scope, [:storage, :email])

      assert Enum.sort(Provisioning.setup_options(project)) == [:email, :storage]
    end

    test "it survives a reload — the whole point", %{scope: scope} do
      {:ok, _} = Provisioning.put_setup_options(scope, [:storage])

      reloaded = Projects.get_project!(scope, scope.active_project.id)

      assert Provisioning.setup_options(reloaded) == [:storage],
             "options did not survive being read back — this is the bug the column exists to fix"
    end

    # The distinction that makes "turn everything off" possible at all.
    test "choosing none is different from never having chosen", %{scope: scope} do
      {:ok, project} = Provisioning.put_setup_options(scope, [])

      assert Provisioning.setup_options(project) == [],
             "an empty choice was read back as the default — Sam cannot turn everything off"

      assert Provisioning.setup_options(%{project | setup_options: nil}) ==
               Provisioning.available_options()
    end

    test "an unknown option is dropped rather than stored", %{scope: scope} do
      {:ok, project} = Provisioning.put_setup_options(scope, [:storage, :not_a_real_option])

      assert Provisioning.setup_options(project) == [:storage]
    end

    # The row outlives the code that wrote it. A stored option whose step was
    # later removed should be ignored, not crash the page that reads it.
    test "an option whose step no longer exists is ignored, not raised on", %{scope: scope} do
      {:ok, project} =
        Projects.update_project(scope, scope.active_project, %{
          setup_options: ["storage", "a_step_we_deleted"]
        })

      assert Provisioning.setup_options(project) == [:storage]
    end
  end

  describe "the plan follows the options" do
    test "a step whose option is off is absent from the plan, not skipped", %{scope: scope} do
      with_storage = Provisioning.plan(scope, [:storage]) |> Enum.map(& &1.key)
      without = Provisioning.plan(scope, []) |> Enum.map(& &1.key)

      assert :storage in with_storage
      refute :storage in without

      # Absent, not present-and-greyed: criterion 7968 is that it never
      # appears in the run at all.
      assert Enum.all?(without, &(&1 != :storage))
    end
  end
end
