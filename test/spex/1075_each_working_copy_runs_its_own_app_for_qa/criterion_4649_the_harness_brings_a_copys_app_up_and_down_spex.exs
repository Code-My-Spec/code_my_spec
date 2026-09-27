defmodule CodeMySpecSpex.Story1108.Criterion4649Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4649 — The harness brings a copy's app up and down.

  Rule: The harness starts, restarts and stops a copy's app.

  Driven over the real wire: the server pushes `ensure_app_running`/
  `stop_app` (`CmsHarnessTest.FakeServer.push_app_event/2`), a real
  `CmsHarness.Project.ChannelClient` receives it and calls the real
  `CmsHarness.AppInstance` — the same round trip
  `lib/code_my_spec_web/channels/harness_project_channel.ex`'s
  `handle_call({:ensure_app_running, ...})` drives in production.
  `AppInstance`'s own machine-touching parts are faked
  (`CmsHarnessTest.FakeAppInstanceRunner`) so this asserts the orchestration
  — the harness genuinely asked, the app genuinely came up and went down —
  without shelling out to `just` or spawning a real process.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "The harness starts a copy's app, then stops it" do
    scenario "a copy whose app comes up cleanly" do
      given_ "a working copy connected to its harness", context do
        rig = app_instance_rig(probe: :serving, current_commit: "deadbeef")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app is reported serving, with its address and commit", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => "deadbeef"} = context.result
        assert context.result["app_url"] =~ ~r{^http://127\.0\.0\.1:\d+$}

        {:ok, context}
      end

      when_ "the server then asks the harness to stop it", context do
        {:ok, Map.put(context, :stop_result, push_app_event("stop_app"))}
      end

      then_ "it is reported stopped", context do
        assert %{"status" => "ok"} = context.stop_result

        assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1)),
               "stop_app reported ok but never actually stopped the process"

        {:ok, context}
      end
    end
  end
end
