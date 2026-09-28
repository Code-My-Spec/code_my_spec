defmodule CodeMySpecSpex.Story1108.Criterion4661Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4661 — A stale app is not reported as current.

  Rule: The copy reports which commit its app is serving.

  Asking whether an already-running app is still up (`ensure_app_running`
  on a copy that never stopped) never re-derives the commit from the
  checkout's current HEAD — it reports what the running process was
  actually started on. If HEAD has since moved without a restart, the app
  genuinely *is* still serving the older commit, and saying otherwise would
  be the lie this criterion rules out: a QA session reading "current" about
  code that was never actually redeployed.
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
