defmodule CodeMySpecSpex.Story1108.Criterion4659Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4659 — An idle app is stopped and comes back when needed.

  Rule: A non-main copy's app stops after 30 minutes with no requests and
  no open QA task.

  The idle window and its re-check interval are both configurable (same
  reasoning as `Intake.Conversation.shape_timeout/0`) so this spex proves
  the stop actually fires without waiting 30 real minutes for it.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "An idle app stops on its own, and a later request brings it back" do
    scenario "the idle window elapses with nothing touching the app" do
      given_ "a working copy with a very short idle window", context do
        rig = app_instance_rig(probe: :serving)
        set_idle_timeout(idle_ms: 10, check_interval_ms: 5)
        {:ok, Map.merge(context, rig)}
      end

      given_ "the app has been started", context do
        result = push_app_event("ensure_app_running")
        assert %{"status" => "ok", "app_status" => "serving"} = result
        {:ok, context}
      end

      then_ "it stops itself once the idle window passes, unasked", context do
        eventually(fn ->
          assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1)),
                 "the idle window passed and nothing stopped the app"
        end)

        {:ok, context}
      end

      when_ "the server asks for it again", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "it comes back up, on the same address", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_url" => url} = context.result
        assert url =~ ~r{^http://127\.0\.0\.1:\d+$}

        {:ok, context}
      end
    end
  end
end
