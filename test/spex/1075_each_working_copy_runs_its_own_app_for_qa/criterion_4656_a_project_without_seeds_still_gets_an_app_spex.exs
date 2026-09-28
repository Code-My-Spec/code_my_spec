defmodule CodeMySpecSpex.Story1108.Criterion4656Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4656 — A project without seeds still gets an app.

  Rule: A project's seeds, when it has them, are applied after the clone.

  Whether a project *has* a `seed` recipe is decided inside `Runner.seed/1`
  itself — the real implementation checks for the recipe before running
  `just seed`; a project with none is a no-op, same as the fake here always
  answers. So `AppInstance`'s own orchestration calls `seed/1`
  unconditionally either way, and this criterion is about the other half:
  nothing upstream of that call treats "no seed recipe" as a reason the app
  shouldn't come up — the clone itself is what makes a fresh copy usable,
  and seeding is strictly additional to it.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "Seeding being a no-op does not stop the app from coming up" do
    scenario "a working copy whose project has nothing to seed" do
      given_ "a working copy with no database yet", context do
        rig = app_instance_rig(database_exists?: false, main_database_name: "myapp_dev")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app comes up, cloned and serving, regardless of what seeding did", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result

        assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:clone_database, _}, &1)),
               "the clone itself is what a project without seeds still needs — " <>
                 "seeding never gates it"

        {:ok, context}
      end
    end
  end
end
