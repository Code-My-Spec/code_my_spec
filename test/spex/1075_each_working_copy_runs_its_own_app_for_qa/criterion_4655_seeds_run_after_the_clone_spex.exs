defmodule CodeMySpecSpex.Story1108.Criterion4655Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4655 — Seeds run after the clone.

  Rule: A project's seeds, when it has them, are applied after the clone.

  See criterion 4656 for the other half of this rule (a project without
  seeds still gets an app).
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "Seeds run after the clone, not before" do
    scenario "a project whose justfile declares a seed recipe" do
      given_ "a working copy with no database yet, whose project seeds itself", context do
        rig = app_instance_rig(database_exists?: false, main_database_name: "myapp_dev")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the app comes up", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result
        {:ok, context}
      end

      then_ "seed ran after clone_database, not before", context do
        order = FakeAppInstanceRunner.calls() |> Enum.map(&elem(&1, 0))
        clone_index = Enum.find_index(order, &(&1 == :clone_database))
        seed_index = Enum.find_index(order, &(&1 == :seed))

        assert clone_index && seed_index && clone_index < seed_index,
               "seed ran before the clone existed to seed, or not at all: #{inspect(order)}"

        {:ok, context}
      end
    end
  end
end
