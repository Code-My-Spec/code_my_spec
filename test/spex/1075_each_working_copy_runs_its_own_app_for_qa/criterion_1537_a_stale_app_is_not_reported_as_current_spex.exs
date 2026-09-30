defmodule CodeMySpecSpex.Story1108.Criterion4661Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4661 — A stale app is not reported as current.

  Rule: The copy reports which commit its app is serving.

  Asking whether an already-running app is still up (`ensure_app_running`
  on a copy that never stopped) never re-derives the commit from the
  checkout's current HEAD — it reports what the running process was
  actually started on.

  Reworded under 79854c2f (John: "we have hot reload, we don't need to
  restart all the time"): `app_commit` deliberately keeps meaning *the
  commit the process launched from*, not *the commit whose code is
  currently being served*. Hot reload can mean those two are no longer the
  same thing — a copy running on `old0000` may already be serving code
  edited since, without ever restarting — and this field does not try to
  track that. It answers a narrower, still-useful question: what got this
  process running. `HEAD moved past it` is a separate fact, surfaced
  alongside rather than folded in — `EnsureAppRunning`'s own reply names
  the running copy and adds "This copy's HEAD is `<head>`: the app is not
  restarted when HEAD moves, only on a promote." when the two diverge,
  rather than silently reporting one number for both questions.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "An app that never restarted still reports the commit it actually started on", criterion: 1537 do
    scenario "HEAD moves after the app is already up, with no restart requested" do
      given_ "a working copy already running an older commit", context do
        rig = app_instance_rig(current_commit: "old0000")
        _ = push_app_event("ensure_app_running")
        {:ok, Map.merge(context, rig)}
      end

      when_ "HEAD moves, but only an ensure (not a restart) is asked for", context do
        FakeAppInstanceRunner.configure(current_commit: "new1111")
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app is still reported on the commit it was actually started with", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => "old0000"} = context.result

        refute context.result["app_commit"] == "new1111",
               "an ensure that never restarted the process must not claim to be " <>
                 "serving code it was never actually redeployed onto"

        {:ok, context}
      end
    end
  end
end
