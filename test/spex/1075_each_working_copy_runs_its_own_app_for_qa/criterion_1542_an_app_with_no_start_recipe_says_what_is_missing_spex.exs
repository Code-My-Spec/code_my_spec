defmodule CodeMySpecSpex.Story1108.Criterion4666Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4666 — An app with no start recipe says what is missing.

  Rule: An app declares how it starts with a recipe that honors PORT and
  DATABASE_NAME.

  A copy whose `justfile` has no `serve` recipe is refused, not silently
  left down with no explanation and not attempted with a guessed command.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "A copy with no serve recipe is refused, not guessed at", criterion: 1542 do
    scenario "the project's justfile declares no serve recipe" do
      given_ "a working copy whose justfile has no serve recipe", context do
        rig = app_instance_rig(recipe: %{"serve" => false})
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "the request is refused by name, saying what is missing", context do
        assert %{"status" => "error", "reason" => reason} = context.result
        assert reason =~ "no_start_recipe"

        {:ok, context}
      end

      then_ "nothing was ever launched", context do
        refute Enum.any?(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1)),
               "a missing recipe should stop this before any launch is attempted"

        {:ok, context}
      end
    end
  end
end
