defmodule CodeMySpec.AgentTasks.ConsistencyTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.{Evaluator, StartAgentTask}

  test "every value in @session_type_map exports command/2" do
    missing =
      StartAgentTask.session_type_map()
      |> Enum.reject(fn {_type, module} ->
        Code.ensure_loaded?(module) and function_exported?(module, :command, 2)
      end)

    assert missing == [],
           "Modules registered in @session_type_map but missing command/2:\n" <>
             Enum.map_join(missing, "\n", fn {type, mod} -> "  #{type} => #{inspect(mod)}" end)
  end

  test "every type listed in @bootstrap_tasks/@project_tasks/@componentless_tasks/@topic_tasks is in @session_type_map" do
    map_keys = StartAgentTask.session_type_map() |> Map.keys() |> MapSet.new()

    orphan_types =
      [
        StartAgentTask.bootstrap_tasks(),
        StartAgentTask.project_tasks(),
        StartAgentTask.componentless_tasks(),
        StartAgentTask.topic_tasks()
      ]
      |> List.flatten()
      |> Enum.reject(&MapSet.member?(map_keys, &1))

    assert orphan_types == [],
           "Types listed in a dispatch list but missing from @session_type_map: " <>
             inspect(orphan_types)
  end

  test "every module in Evaluator.custom_evaluate_modules/0 exports evaluate/2" do
    missing =
      Evaluator.custom_evaluate_modules()
      |> Enum.reject(fn module ->
        Code.ensure_loaded?(module) and function_exported?(module, :evaluate, 2)
      end)

    assert missing == [],
           "Modules in custom_evaluate_modules/0 not exporting evaluate/2: " <>
             inspect(missing)
  end

  test "every module in Evaluator.custom_evaluate_modules/0 is in @session_type_map" do
    map_modules = StartAgentTask.session_type_map() |> Map.values() |> MapSet.new()

    stale =
      Evaluator.custom_evaluate_modules()
      |> Enum.reject(&MapSet.member?(map_modules, &1))

    assert stale == [],
           "Modules in custom_evaluate_modules/0 not reachable via @session_type_map: " <>
             inspect(stale)
  end
end
