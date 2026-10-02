defmodule CodeMySpecWeb.HealthControllerTest do
  @moduledoc """
  `/health` on :4000: what a promote's `just reload` asks after reloading.
  200 with the database answering and nothing pending; whether a harness is
  connected is reported and never fails it.
  """

  use CodeMySpecTest.ConnCase, async: true

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.AppHealth

  test "a migrated database answers 200, harness or not", %{conn: conn} do
    body = conn |> get(~p"/health") |> json_response(200)

    assert %{"status" => "ok", "database" => "ok", "pending_migrations" => []} = body
    assert is_boolean(body["harness_connected"])
  end

  test "a harness connected at the server's checkout is reported" do
    root = "/tmp/app-health-#{System.unique_integer([:positive])}"
    refute AppHealth.check(root).harness_connected

    :ok = HarnessRegistry.register_executor(Ecto.UUID.generate(), "i", root)

    assert %{healthy: true, harness_connected: true} = AppHealth.check(root)
  end
end
