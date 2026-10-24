defmodule CodeMySpecSpex.Story1108.Criterion4664Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4664 — Offboarding cleans up.

  Rule: Offboarding a copy stops its app and drops its database.

  Piggybacked on the existing `"offboard"` push — the harness already gets
  told to release a copy's channel and watchers at exactly this moment, and
  `CmsHarness.AppInstance.discard/1` rides the same event rather than a new
  channel verb. Answered fire-and-forget, like the rest of what `"offboard"`
  does, so this polls for the effect rather than awaiting a reply.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner
  alias CmsHarnessTest.FakeServer

  spex "Offboarding stops the app and drops its cloned database", criterion: 1540 do
    scenario "a copy with a running, cloned app is offboarded" do
      given_ "a working copy whose app is up, on its own cloned database", context do
        rig = app_instance_rig(database_exists?: false, main_database_name: "myapp_dev")
        _ = push_app_event("ensure_app_running")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server offboards the copy", context do
        :ok = FakeServer.push_event("offboard", %{"instance_disposition" => "discard"})
        {:ok, context}
      end

      then_ "the app was stopped", context do
        eventually(fn ->
          assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:stop_process, _}, &1)),
                 "offboarding released the channel without ever stopping the app"
        end)

        {:ok, context}
      end

      then_ "and its cloned database was dropped", context do
        eventually(fn ->
          assert Enum.any?(FakeAppInstanceRunner.calls(), &match?({:drop_database, _}, &1)),
                 "offboarding stopped the app but left its cloned database behind"
        end)

        {:ok, context}
      end
    end
  end
end
