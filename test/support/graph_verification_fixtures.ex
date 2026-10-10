defmodule CodeMySpecSpex.Fixtures.GraphVerification do
  @moduledoc "Controlled projection faults for the verification page's scenarios."
  import Ecto.Query
  import ExUnit.Assertions

  alias CodeMySpec.Repo
  alias CodeMySpec.Requirements
  alias CodeMySpec.Requirements.DrainCost
  alias CodeMySpec.Requirements.GraphWatcher
  alias CodeMySpec.Requirements.Node
  alias CodeMySpec.Requirements.ShadowProjector

  def seed(scope) do
    previous =
      for key <- [:graph_event_is_source, :graph_shadow_projection],
          do: {key, Application.get_env(:code_my_spec, key, false)}

    Enum.each(previous, fn {key, _} -> Application.put_env(:code_my_spec, key, true) end)

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(previous, fn {key, value} -> Application.put_env(:code_my_spec, key, value) end)
    end)

    {:ok, _} = GraphWatcher.ensure_watching(scope)
    :ok = GraphWatcher.settle(scope)
    :ok = ShadowProjector.settle(scope.active_project_id, [nil, scope.active_working_copy_id])
    Requirements.recompute(scope)
    :ok
  end

  def change_waiting(scope) do
    {count, _} =
      Repo.update_all(
        from(n in Node,
          where: n.project_id == ^scope.active_project_id and n.name == "personas_complete"
        ),
        set: [details: %{"waiting_on" => "verification probe"}]
      )

    assert count > 0
    :ok
  end

  def fail_drain(scope) do
    assert_raise RuntimeError, "verification probe", fn ->
      DrainCost.measure(
        %{kind: :event, project_id: scope.active_project_id, observations: 1},
        fn ->
          raise "verification probe"
        end
      )
    end

    :ok
  end
end
