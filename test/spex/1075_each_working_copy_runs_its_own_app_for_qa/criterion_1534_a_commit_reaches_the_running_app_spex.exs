defmodule CodeMySpecSpex.Story1108.Criterion4658Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4658 — A commit reaches the running app.

  Rule (79854c2f): a copy's app keeps running when the copy's HEAD moves;
  hot reload picks up code changes, so it is only restarted when it is not
  already running. John: "we have hot reload, we don't need to restart all
  the time."

  This scenario is still the case a restart genuinely happens — the app was
  not running (or a caller asked for one directly) — so what a restart
  brings up has to be the copy's *current* commit, not whichever one the
  process last started on. Asserted through `restart_app` itself, the door
  a restart actually goes through, not through the checkout's git state,
  which is a fact this feature reads rather than one it owns.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A restart brings the app up on the copy's current commit", criterion: 1534 do
    scenario "HEAD has moved to a new commit since the app last started" do
      given_ "a working copy already serving an older commit", context do
        rig = app_instance_rig(current_commit: "old0000")
        {:ok, Map.merge(context, rig)}
      end

      given_ "the app is up and running", context do
        _ = push_app_event("ensure_app_running")
        {:ok, context}
      end

      when_ "HEAD moves and the server asks for a restart", context do
        FakeAppInstanceRunner.configure(current_commit: "new1111")
        {:ok, Map.put(context, :result, push_app_event("restart_app"))}
      end

      then_ "the app is reported serving the new commit", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => "new1111"} = context.result
        {:ok, context}
      end
    end
  end
end
