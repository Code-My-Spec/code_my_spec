defmodule CodeMySpec.StaffingReportsRegistrationOutcomeTest do
  @moduledoc """
  Issue 37f35126. `Staffing.mint/2`'s own registration
  (`WorkingCopies.issue/3`, `report_root/2`) runs in the caller's process,
  after the harness's channel has already replied to the
  "create_working_copy_result" push that unblocked it -- so the harness's
  transport-level ack of that push could never carry whether registration
  itself succeeded. `mint/2` now reports the real outcome explicitly, to
  whichever machine made the checkout, as soon as it is known.

  Reaching the real machine in a test means a real `HarnessRegistry` entry:
  `register_executor/3` registers the *calling* process, so the test
  process stands in for "the machine" and receives exactly what
  `Transport.Harness.report_working_copy_registration/3` would have sent a
  real channel.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Staffing
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    n = System.unique_integer([:positive])

    root = "/tmp/registration-host-#{n}"
    {:ok, host} = WorkingCopies.issue(scope, nil, root: root, device: device)
    {:ok, host} = WorkingCopies.report_root(host, root)

    :ok = HarnessRegistry.register_executor(host.id, "test", host.root)

    %{scope: scope}
  end

  test "a successful registration reports :ok for the new copy's own id", %{scope: scope} do
    {:ok, copy, _staffed} = Staffing.mint(scope, label: "registration check")

    assert_receive {:working_copy_registered, working_copy_id, :ok}
    assert working_copy_id == copy.id
  end

  test "a registration failure reports the error, and mint/2 answers it too", %{scope: scope} do
    :meck.new(WorkingCopies, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(WorkingCopies) end)

    :meck.expect(WorkingCopies, :issue, fn _scope, _id, _opts -> {:error, :forced_failure} end)

    assert {:error, :forced_failure} = Staffing.mint(scope, label: "registration check")

    assert_receive {:working_copy_registered, _working_copy_id, {:error, :forced_failure}}
  end
end
