defmodule CodeMySpecTest.PromotionQueueHelpers do
  @moduledoc "Waiting on, and stopping, a project's promotion queue worker in tests."

  alias CodeMySpec.PromotionQueue

  @doc "Explicit compatibility opt-in for fixtures without an origin repository."
  def local_promotion_project(scope) do
    key = :local_promotion_projects
    original = Application.get_env(:code_my_spec, key, [])
    Application.put_env(:code_my_spec, key, [scope.active_project_id | original])
    ExUnit.Callbacks.on_exit(fn -> Application.put_env(:code_my_spec, key, original) end)
  end

  @doc "Stop the project's worker, if it is running."
  def stop_worker(project_id),
    do: CodeMySpec.PromotionQueue.Registry |> Registry.lookup(project_id) |> terminate()

  defp terminate([{pid, _}]),
    do: DynamicSupervisor.terminate_child(CodeMySpec.PromotionQueue.Supervisor, pid)

  defp terminate([]), do: :ok

  @doc "The entry's final state, however the wait ended."
  def settle(entry, timeout \\ 15_000),
    do: entry |> PromotionQueue.await(timeout) |> settled(entry)

  defp settled({:landed, _report}, entry), do: {:ok, PromotionQueue.get(entry.id)}
  defp settled(other, _entry), do: other
end
