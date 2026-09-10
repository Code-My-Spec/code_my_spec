defmodule CodeMySpec.McpServers.Tasks.Tools.TapOutIsIdempotentTest do
  @moduledoc """
  Calling `tap_out` again while a request is still pending must not create a
  second one.

  An agent asks once and is told to stop, not to ask again — but
  `wake_project_roles/2`'s missing guard (fixed alongside this) handed a menu
  still offering `tap_out` to an agent with one already pending, on every
  unrelated project change. Every retry created a fresh `PermissionRequest`
  row, because the tool never checked for one first.

  Measured live on 2026-09-10: 224 pending tap-out rows behind ten agents,
  one of them holding 129 — the backlog a human "has no way to administer"
  was mostly the tool asking the same question over and over, not 224 people
  waiting on a decision.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  import Ecto.Query

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.McpServers.Tasks.Tools.TapOut
  alias CodeMySpec.Notifications.PermissionRequest
  alias CodeMySpec.Repo
  alias CodeMySpecSpex.TaskResponseHelpers

  setup do
    scope = full_scope_fixture()

    {:ok, copy} =
      CodeMySpec.WorkingCopies.issue(scope, nil,
        label: "a checkout",
        device: device_fixture(scope)
      )

    {:ok, agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        continuous: true,
        working_copy: "/tmp/tapout-idempotent-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope: scope, agent: agent}
  end

  defp frame(scope, agent),
    do: %Anubis.Server.Frame{assigns: %{current_scope: scope, agent_id: agent.id}}

  defp pending_count(agent_id) do
    PermissionRequest
    |> where([p], p.agent_id == ^agent_id and p.tool_name == "tap_out" and p.status == "pending")
    |> Repo.aggregate(:count)
  end

  defp request_id(response) do
    [_, id] = Regex.run(~r/request_id=`([^`]+)`/, TaskResponseHelpers.response_text(response))
    id
  end

  test "a second call while one is pending creates no new row", %{scope: scope, agent: agent} do
    {:reply, first, _} = TapOut.execute(%{}, frame(scope, agent))
    {:reply, second, _} = TapOut.execute(%{}, frame(scope, agent))

    refute first.isError
    refute second.isError
    assert pending_count(agent.id) == 1
  end

  test "the second call reports the same request id as the first", %{scope: scope, agent: agent} do
    {:reply, first, _} = TapOut.execute(%{}, frame(scope, agent))
    {:reply, second, _} = TapOut.execute(%{}, frame(scope, agent))

    assert request_id(second) == request_id(first)
  end

  # Once it is decided, asking again is a new question and must get a new row
  # — an agent that was told to keep going is allowed to ask again later.
  test "once resolved, the next call opens a new request", %{scope: scope, agent: agent} do
    {:reply, first, _} = TapOut.execute(%{}, frame(scope, agent))
    first_id = request_id(first)

    {:ok, _} = CodeMySpec.Notifications.resolve_permission_request(first_id, "deny")

    {:reply, second, _} = TapOut.execute(%{}, frame(scope, agent))

    refute request_id(second) == first_id
    assert pending_count(agent.id) == 1
  end
end
