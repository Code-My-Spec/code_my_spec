defmodule CodeMySpecTest.OwnDispatches do
  @moduledoc """
  Waits for the dispatch tasks the calling test started.

  `CodeMySpec.TaskSupervisor` is global, so an async test that waited for
  every child also waited on other tests' longer tasks and timed out in the
  full suite. A task records who spawned it in `:"$callers"`.
  """

  import ExUnit.Assertions

  def await(timeout \\ 5_000) do
    test = self()

    CodeMySpec.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(&started_by?(&1, test))
    |> Enum.map(&Process.monitor/1)
    |> Enum.each(fn ref -> assert_receive {:DOWN, ^ref, _, _, _}, timeout end)
  end

  defp started_by?(pid, test) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> test in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end
end
