defmodule CodeMySpecSpex.Story1108.Criterion4654Spex do
  @moduledoc """
  Story 1108 — Each working copy runs its own app for QA.
  Criterion 4654 — Cloning while main's app is running.

  Rule: A non-main copy's database starts as a clone of main's dev database.

  `AppInstance`'s own orchestration never asks whether main's app is busy
  before cloning, because the answer does not change what it does — cloning
  happens once, straight through, with no retry or wait built around it.
  That is what makes this criterion true at the orchestration layer.

  What actually makes concurrent cloning *safe* — `pg_dump` takes an
  MVCC-consistent snapshot without blocking on open connections, unlike
  `CREATE DATABASE ... TEMPLATE`, which Postgres refuses outright against a
  database that has any — lives in `CmsHarness.AppInstance.Runner.Local.
  clone_database/3`'s real implementation, verified once by hand against
  this project's own working copy (the story 1108 handoff) rather than
  re-proven here: this project's own rule is that spex do not shell out to
  a real Postgres server.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  spex "Cloning happens once, straight through — nothing waits for main to be idle" do
    scenario "a working copy cloning main's data on first start" do
      given_ "a working copy with no database of its own yet", context do
        rig = app_instance_rig(database_exists?: false, main_database_name: "myapp_dev")
        {:ok, Map.merge(context, rig)}
      end

      when_ "the server asks the harness to ensure the app is running", context do
        {:ok, Map.put(context, :result, push_app_event("ensure_app_running"))}
      end

      then_ "clone_database was called exactly once, with no retry or wait around it", context do
        assert %{"status" => "ok", "app_status" => "serving"} = context.result

        clone_calls = Enum.filter(FakeAppInstanceRunner.calls(), &match?({:clone_database, _}, &1))

        assert length(clone_calls) == 1,
               "a retry loop here would be the orchestration polling for main to go " <>
                 "idle before cloning — this rule holds because there is nothing to " <>
                 "wait for, not because a wait happened to succeed on the first try"

        {:ok, context}
      end
    end
  end
end
