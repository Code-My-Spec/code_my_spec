defmodule CodeMySpec.Agents.ALandingNoticeSurvivesTheCodeReloadTest do
  @moduledoc """
  A landing's team-free notice is not lost to the dev server's code reload.

  The notice fires as the batch merges into the checkout the server runs, and
  a module the reloader is swapping at that instant is undefined. Story 1066's
  notice was lost that way at 03:17:21 and team 2 sat idle for 40 minutes
  (2026-10-14).
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Agents.Events

  test "a module undefined mid-reload is tried again once the reload settles" do
    test = self()
    calls = :counters.new(1, [])

    fun = fn ->
      :counters.add(calls, 1, 1)
      notify(:counters.get(calls, 1), test)
    end

    assert :ok = Events.across_reload(:promotion_team_free, fun, 1, 10)
    assert_receive :notified, 2_000
  end

  defp notify(1, _test),
    do: raise(UndefinedFunctionError, module: Reloading, function: :now, arity: 0)

  defp notify(_call, test), do: send(test, :notified)

  test "any other failure is logged with where it happened, not retried" do
    test = self()

    log =
      capture_log(fn ->
        Events.across_reload(
          :promotion_team_free,
          fn ->
            send(test, :ran)
            raise ArgumentError, "a real defect"
          end,
          1,
          10
        )
      end)

    assert_received :ran
    refute_receive :ran, 100
    assert log =~ "promotion_team_free failed"
    assert log =~ "a real defect"
    assert log =~ __ENV__.file |> Path.basename()
  end
end
