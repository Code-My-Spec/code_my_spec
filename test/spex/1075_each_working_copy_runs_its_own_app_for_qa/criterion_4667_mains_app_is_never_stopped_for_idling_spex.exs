defmodule CodeMySpecSpex.Story1108.Criterion4667Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4667 — Main's app is never stopped for idling.

  Rule: A non-main copy's app stops after 30 minutes with no requests and
  no open QA task.

  `AppInstance` has no way to know it is main on its own — only the server
  designates one — so it is told fresh on every `ensure_app_running`/
  `restart_app` request (`main: true` on the push, the way
  `HarnessProjectChannel.put_main/2` sends it) rather than remembered.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "Main's app outlives the idle window that would stop any other copy's" do
    scenario "the designated copy, started as main, sits idle" do
      given_ "main's working copy, with a very short idle window", context do
        rig = app_instance_rig(probe: :serving)
        set_idle_timeout(idle_ms: 10, check_interval_ms: 5)
        {:ok, Map.merge(context, rig)}
      end

      given_ "started as this project's designated copy", context do
        result = push_app_event_as_main("ensure_app_running")
        assert %{"status" => "ok", "app_status" => "serving"} = result
        {:ok, context}
      end

      when_ "several idle windows pass with nothing touching it", context do
        Process.sleep(50)
        {:ok, context}
      end

      then_ "it was never stopped", context do
        refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1)),
               "main's app was stopped for idling — that is the one thing this rule forbids"

        {:ok, context}
      end
    end
  end
end
