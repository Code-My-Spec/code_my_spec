defmodule CodeMySpec.Hooks.AContinuousTerminalMainIsNotOfferedDevelopmentWorkTest do
  @moduledoc """
  A terminal main that is continuous (so the cadence reaches it) is not held at
  every stop and handed the graph's development requirements.

  Issue c611917d. After the Sessions removal the stop hook read continuity from
  the terminal agent, and a continuous main was blocked with "26 requirements"
  that are a coder's, not main's. The stop is judged against the agent's own
  role, as an agent we run is.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.Integration.WorkflowHelpers

  alias CodeMySpec.Hooks.Stop
  alias CodeMySpec.Requirements
  alias CodeMySpec.TaskOwner
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  test "its stop is allowed when the graph holds only development work" do
    %{scope: scope, agent: agent, external_session_id: session_id} = setup_workflow_scenario()

    {:ok, _} = TaskOwner.set_continuous(agent, true)
    Requirements.recompute(scope)

    response =
      scope
      |> Stop.decide(%{"session_id" => session_id})
      |> Jason.encode!()
      |> Jason.decode!()

    refute response["decision"] == "block",
           "a continuous main was held at its stop: #{inspect(response)}"
  end
end
