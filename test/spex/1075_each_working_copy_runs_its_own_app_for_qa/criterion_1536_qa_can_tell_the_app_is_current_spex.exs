defmodule CodeMySpecSpex.Story1108.Criterion4660Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4660 — QA can tell the app is current.

  Rule: The copy reports which commit its app is serving.

  See criterion 4661 for the other half of this rule (a stale app is not
  reported as current).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  spex "The app reports the exact commit it was started on", criterion: 1536 do
    scenario "a copy starting for the first time" do
      given_ "a working copy about to start on a known commit", context do
        rig = app_instance_rig(current_commit: "feedface")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "QA is told exactly which commit is serving", context do
        assert %{"status" => "ok", "app_status" => "serving", "app_commit" => "feedface"} = context.result
        {:ok, context}
      end
    end
  end
end
