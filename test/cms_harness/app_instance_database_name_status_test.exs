defmodule CmsHarness.AppInstanceDatabaseNameStatusTest do
  @moduledoc """
  Issue 1f90f048/story 1013: a plain `mix run`/`iex -S mix` run by hand in a
  working copy never had DATABASE_NAME set -- only the harness-managed boot
  does -- so it silently queried the shared main database instead of this
  copy's own, a result that looks right and is wrong. AppInstance now writes
  the copy's assigned database name to a file inside the checkout, where
  config/dev.exs reads it back.
  """

  # Sync: `app_instance_rig` sets application env.
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarness.AppInstance

  describe "a non-main copy" do
    test "records its assigned database name inside the checkout" do
      %{root: root} = app_instance_rig(database_exists?: true)
      assert %{"status" => "ok", "app_status" => "serving"} = push_app_event("ensure_app_running")

      state = :sys.get_state(GenServer.whereis(AppInstance.via(root)))
      path = Path.join(root, ".code_my_spec/status/database_name")

      assert File.read!(path) == state.database
    end
  end

  describe "the main copy" do
    test "writes no database name status file -- its own config/dev.exs is the record" do
      %{root: root} = app_instance_rig(database_exists?: true)

      assert %{"status" => "ok", "app_status" => "serving"} =
               push_app_event_as_main("ensure_app_running")

      refute File.exists?(Path.join(root, ".code_my_spec/status/database_name")),
             "main's database is config/dev.exs's own literal default, not a per-copy name"
    end
  end
end
