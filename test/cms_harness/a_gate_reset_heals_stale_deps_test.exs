defmodule CmsHarness.AGateResetHealsStaleDepsTest do
  @moduledoc """
  The promotion gate's test-database reset is healed like an analyzer run.

  A candidate that moved `mix.lock` left the gate checkout's `deps/` behind it,
  and mix refused the reset's first command, "Unchecked dependencies", on every
  retry: code_my_spec's queue wedged for every candidate (2026-10-12).
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Analysis
  alias CodeMySpec.Promotion.Steps
  alias CodeMySpec.Support.InMemoryEnvironment

  @stale """
  Unchecked dependencies for environment test:
  * alloy (https://github.com/Code-My-Spec/alloy.git - main)
    lock mismatch: the dependency is out of date. To fetch locked version run "mix deps.get"
  ** (Mix) Can't continue due to errors on dependencies
  """

  defp a_gate(fetched?) do
    test = self()

    {:ok, env} =
      InMemoryEnvironment.create(
        shell: fn "mix", args, _opts ->
          send(test, {:mix, args})
          answer(args, fetched?)
        end
      )

    env
  end

  defp answer(["deps.get"], fetched?) do
    :counters.put(fetched?, 1, 1)
    {"fetched\n", 0}
  end

  defp answer(["run" | _], fetched?), do: drop(:counters.get(fetched?, 1))

  defp drop(0), do: {@stale, 1}
  defp drop(1), do: {"dropped\n", 0}

  defp reset(env) do
    Analysis.heal(env, fn -> as_text(Steps.reset_test_databases(env, "/w/gate", ["ha"])) end)
  end

  defp as_text({:error, %{reason: reason}}), do: {:error, reason}
  defp as_text(result), do: result

  test "a reset refused for stale deps fetches once and resets" do
    env = a_gate(:counters.new(1, []))

    assert {:ok, %{dropped: ["ha"]}} = reset(env)
    assert_received {:mix, ["run" | _]}
    assert_received {:mix, ["deps.get"]}
    assert_received {:mix, ["run" | _]}
  end

  test "a reset whose deps are current fetches nothing" do
    fetched = :counters.new(1, [])
    :counters.put(fetched, 1, 1)

    assert {:ok, %{dropped: ["ha"]}} = reset(a_gate(fetched))
    refute_received {:mix, ["deps.get"]}
  end
end
