defmodule CodeMySpecSpex.Story1108.Criterion4653Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4653 — First start clones main's data.

  Rule: A non-main copy's database starts as a clone of main's dev database.

  See criterion 4654 for the other half of this rule (cloning while main's
  app is running).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A copy with no database yet gets one cloned from main on first start" do
    scenario "database_exists? starts false" do
      given_ "a working copy with no database of its own yet", context do
        rig = app_instance_rig(database_exists?: false, main_database_name: "myapp_dev")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app comes up serving", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      then_ "main's database was cloned, not created empty", context do
        assert Enum.any?(
                 FakeAppInstanceRunner.calls(),
                 &match?({:clone_database, [_root, "myapp_dev", _database]}, &1)
               ),
               "the app came up without ever cloning main's data"

        {:ok, context}
      end
    end
  end
end
