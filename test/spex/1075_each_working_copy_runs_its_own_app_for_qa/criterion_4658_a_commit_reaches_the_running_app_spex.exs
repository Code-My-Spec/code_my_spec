defmodule CodeMySpecSpex.Story1108.Criterion4658Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4658 — A commit reaches the running app.

  Rule: A copy's app restarts when the copy's HEAD moves.

  Asserted through `restart_app`, the verb the server pushes when it
  notices a copy's HEAD moved — not through the checkout's git state
  itself, which is a fact this feature reads rather than one it owns.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A restart brings the app up on the copy's current commit" do
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
