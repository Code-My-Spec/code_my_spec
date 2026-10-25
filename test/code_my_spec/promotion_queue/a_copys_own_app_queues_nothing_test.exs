defmodule CodeMySpec.PromotionQueue.ACopysOwnAppQueuesNothingTest do
  @moduledoc """
  A working copy's own app runs on a clone of main's database, so it holds
  main's queue. It neither takes a promotion nor runs a worker: one there
  would gate and publish beside main's.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.PromotionQueue

  setup do
    previous = System.get_env("CMS_MAIN_COPY")
    System.put_env("CMS_MAIN_COPY", "false")

    on_exit(fn -> restore(previous) end)

    %{scope: full_scope_fixture()}
  end

  defp restore(nil), do: System.delete_env("CMS_MAIN_COPY")
  defp restore(previous), do: System.put_env("CMS_MAIN_COPY", previous)

  test "a promote is refused, and no worker starts", %{scope: scope} do
    assert {:error, %{reason: reason}} = PromotionQueue.enqueue(scope, nil)
    assert reason =~ "working copy's own app"

    assert [] = Registry.lookup(CodeMySpec.PromotionQueue.Registry, scope.active_project_id)
  end
end
