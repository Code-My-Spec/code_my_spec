defmodule CodeMySpec.EveryWorkingCopyIsPreparedAtCreationTest do
  @moduledoc """
  Issue b1345aaf: issues team 4's copy came onto the harness without its
  envs decrypted or its test database created, so the first thing ExUnit
  did was raise `GITHUB_CLIENT_ID not set`. Root cause, traced to
  `Staffing.mint/2`: the harness only ran the project's `gate-setup` recipe
  (envs decryption, `deps.get`, `ecto.create`, `ecto.migrate`) when the
  caller explicitly passed `prepare: true`, and the only caller that did was
  the promotion queue's own gate copy. An agent asking for somewhere to work
  (the `create_working_copy` tool) and `EpicDispatch` placing an epic never
  did, so every ordinary team/agent working copy shipped unprepared.

  John, 2026-10-19, verbatim: "we should for sure do all the setup on every
  copy at creation. env and test db at creation." This asserts the request
  `mint/2` hands the harness names `prepare: true` regardless of whether the
  caller mentions it at all -- the shape of an ordinary agent's own copy and
  of an epic's copy, not just the gate copy's.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Staffing
  alias CodeMySpec.WorkingCopies

  defmodule CapturingTransport do
    @moduledoc """
    Sends the server's own `create_working_copy` request to the test process
    and refuses it, rather than making a real checkout -- what is under test
    is the request `mint/2` builds, not the harness's reply to it.
    """
    @behaviour CodeMySpec.Agents.Transport

    @impl true
    def create_working_copy(_candidates, request, _timeout) do
      send(self(), {:create_working_copy_request, request})
      {:error, :no_harness}
    end

    @impl true
    def start_agent(_working_copy_id, _agent, _timeout), do: {:error, :not_implemented}

    @impl true
    def dispatch_message(_working_copy_id, _agent, _ref, _message, _timeout),
      do: {:error, :not_implemented}

    @impl true
    def request_work_turn(_working_copy_id, _agent, _ref, _message, _timeout),
      do: {:error, :not_implemented}

    @impl true
    def call_machine_tool(_working_copy_id, _tool, _arguments, _timeout),
      do: {:error, :not_implemented}

    @impl true
    def stop_agent(_working_copy_id, _agent, _timeout), do: {:error, :not_implemented}
  end

  setup do
    scope = full_scope_fixture()
    device = CodeMySpec.DevicesFixtures.device_fixture(scope)
    n = System.unique_integer([:positive])

    # A rooted candidate host, the same way minted_copy_matches_what_was_written_test.exs
    # gives mint/2 somewhere to make a sibling worktree beside -- a scope's
    # own working copy has no root by default, so with none, mint/2 never
    # reaches the transport at all.
    root = "/tmp/prepare-host-#{n}"
    {:ok, host} = WorkingCopies.issue(scope, nil, root: root, device: device)
    {:ok, _host} = WorkingCopies.report_root(host, root)

    :ok = CodeMySpecTest.AgentTransportRouter.route(scope, CapturingTransport)

    %{scope: scope}
  end

  test "an agent asking for somewhere to work gets a copy the harness will prepare", %{
    scope: scope
  } do
    Staffing.mint(scope, label: "an agent's own working copy")

    assert_received {:create_working_copy_request, request}

    assert request["prepare"] == true,
           "an ordinary agent's working copy was requested without prepare: true, so " <>
             "it would come onto the harness with no decrypted envs and no test " <>
             "database -- exactly the GITHUB_CLIENT_ID failure this issue reports."
  end

  test "an epic's working copy is requested prepared the same way", %{scope: scope} do
    Staffing.mint(scope, label: "an epic's working copy")

    assert_received {:create_working_copy_request, request}
    assert request["prepare"] == true
  end
end
