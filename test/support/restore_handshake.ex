defmodule CodeMySpecSpex.Fixtures.RestoreHandshake do
  @moduledoc "Exercises restoration through a joined channel and its deferred reply."
  import Phoenix.ChannelTest
  import ExUnit.Assertions

  @endpoint CodeMySpecWeb.Endpoint

  def agents(scope) do
    {:ok, _reply, joined} =
      CodeMySpecWeb.UserSocket
      |> socket("restore-fixture", %{scope: scope})
      |> subscribe_and_join(
        CodeMySpecWeb.HarnessProjectChannel,
        "harness_project:#{scope.active_project_id}",
        %{
          "label" => "restoring harness",
          "harness_id" => scope.active_working_copy_id,
          "device" => %{"id" => CodeMySpec.DevicesFixtures.device_fixture(scope).id}
        }
      )

    ref = push(joined, "agents_to_restore", %{})
    assert_reply ref, :ok, %{"agents" => agents}, 5_000
    agents
  end
end
