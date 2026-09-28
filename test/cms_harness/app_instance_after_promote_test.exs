defmodule CmsHarness.AppInstanceAfterPromoteTest do
  @moduledoc """
  Story 1108, criterion 4663/1539: the after-promote hook's own failure.

  `criterion_1539_..._spex.exs` proves the hook is gated on `main?` and that
  a successful run doesn't get skipped. It deliberately does not provoke a
  *failing* run: this project's spex-wide `SexySpex.ErrorCapture` fails any
  spex that logs at `:error` during its run, and a failing after-promote
  hook does exactly that on purpose (`AppInstance.after_promote/1`'s own
  `Logger.error`). A plain, non-spex `ExUnit.Case` has no such handler
  installed, so `ExUnit.CaptureLog` can assert on it directly instead of
  tripping that rule.

  `async: false`, matching every other `app_instance_rig`-based test:
  the rig configures `Application.put_env(:code_my_spec, CmsHarness.AppInstance, ...)`
  and a singleton, named `FakeAppInstanceRunner` — both node-global state a
  second async test elsewhere could race.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  test "a failing after-promote hook still reports the restart as serving, and logs loudly" do
    app_instance_rig(
      current_commit: "cafef00d",
      recipe: %{"after-promote" => true},
      after_promote_result: {:error, "refresh-harness exited 1"}
    )

    log =
      capture_log(fn ->
        result = push_app_event_as_main("restart_app")

        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => "cafef00d"} =
                 result
      end)

    assert log =~ "after-promote failed"
    assert log =~ "refresh-harness exited 1"

    assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:run_after_promote, _}, &1)),
           "the hook has to have actually run for its failure to be the thing under test"
  end
end
