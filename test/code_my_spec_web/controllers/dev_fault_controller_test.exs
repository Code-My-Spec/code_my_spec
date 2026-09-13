defmodule CodeMySpecWeb.DevFaultControllerTest do
  @moduledoc """
  The door QA uses to break one thing.

  Issue `0fb7bf03`. What matters here is not that a fault can be injected — it
  is that a name nothing reads is refused. A fault that is accepted and never
  fires reads as "the product handled it", which is a false pass, and a false
  pass on a failure-handling criterion is worse than the refusal these routes
  exist to end.
  """

  use CodeMySpecTest.ConnCase, async: false

  alias CodeMySpec.Faults

  setup do
    on_exit(fn -> Faults.clear_all() end)
    :ok
  end

  describe "POST /dev/faults" do
    test "injects against one key", %{conn: conn} do
      body =
        conn
        |> post(~p"/dev/faults", %{"key" => "project-a", "fault" => "digest_unavailable"})
        |> json_response(200)

      assert body["status"] == "injected"
      assert Faults.active?("project-a", :digest_unavailable)
      refute Faults.active?("project-b", :digest_unavailable)
    end

    test "refuses a fault nothing checks for, and names the real ones", %{conn: conn} do
      body =
        conn
        |> post(~p"/dev/faults", %{"key" => "project-a", "fault" => "make_it_slow"})
        |> json_response(422)

      assert "digest_unavailable" in body["known"]
      assert Faults.list() == []
    end
  end

  describe "DELETE /dev/faults" do
    test "puts one back", %{conn: conn} do
      :ok = Faults.inject("project-a", :digest_unavailable)

      conn
      |> delete(~p"/dev/faults", %{"key" => "project-a", "fault" => "digest_unavailable"})
      |> json_response(200)

      refute Faults.active?("project-a", :digest_unavailable)
    end

    test "clears everything when asked outright", %{conn: conn} do
      :ok = Faults.inject("project-a", :digest_unavailable)
      :ok = Faults.inject("session-1", :intake_shaper_fails)

      body = conn |> delete(~p"/dev/faults", %{"all" => true}) |> json_response(200)

      assert body["removed"] == 2
      assert Faults.list() == []
    end
  end

  describe "GET /dev/faults" do
    test "says what is injected and what could be", %{conn: conn} do
      :ok = Faults.inject("project-a", :digest_unavailable)

      body = conn |> get(~p"/dev/faults") |> json_response(200)

      assert [%{"key" => "project-a", "fault" => "digest_unavailable"}] = body["injected"]
      assert Enum.any?(body["available"], &(&1["fault"] == "intake_shaper_fails"))
    end
  end

  describe "GET /dev/intake/plans" do
    test "hands back the token that addresses a plan", %{conn: conn} do
      {:ok, plan} = CodeMySpec.Intake.start_plan("a-token-#{System.unique_integer([:positive])}")

      body = conn |> get(~p"/dev/intake/plans") |> json_response(200)

      assert Enum.any?(body["plans"], &(&1["session_token"] == plan.session_token))
    end
  end
end
