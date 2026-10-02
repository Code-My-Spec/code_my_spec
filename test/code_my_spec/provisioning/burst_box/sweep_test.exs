defmodule CodeMySpec.Provisioning.BurstBox.SweepTest do
  @moduledoc """
  `:list` is injected the same reason `CodeMySpec.Provisioning.Builder`'s own
  `reap_orphaned_builders/2` injects `:list` — this is a unit test over the
  "which boxes get a check at all" and "one bad box must not sink the sweep"
  logic, not a round trip to Hetzner.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Provisioning.BurstBox.Sweep
  alias CodeMySpec.Users.Scope

  defp scope, do: %Scope{}

  defp due_now, do: fn -> ~U[2026-08-03 12:55:30Z] end

  defp burst_server(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 7,
        "name" => "burst-platform",
        "created" => "2026-08-03T12:00:00Z",
        "labels" => %{Sweep.role_label() => "platform"}
      },
      overrides
    )
  end

  defp other_server(overrides \\ %{}) do
    Map.merge(%{"id" => 1, "name" => "builder-abc123", "created" => "2026-08-03T12:00:00Z"}, overrides)
  end

  describe "sweep_now/2" do
    test "only ever checks servers carrying the burst-box label" do
      list = fn _scope -> {:ok, [burst_server(), other_server()]} end
      busy? = fn _scope, server -> server["id"] == 7 end

      assert [result] = Sweep.sweep_now(scope(), list: list, now: due_now(), busy?: busy?)
      assert result == :kept
    end

    test "deletes an idle burst box, keeps a busy one, across several boxes in one sweep" do
      owner = self()
      idle = burst_server(%{"id" => 1, "name" => "burst-idle"})
      busy = burst_server(%{"id" => 2, "name" => "burst-busy"})

      list = fn _scope -> {:ok, [idle, busy]} end
      busy? = fn _scope, server -> server["name"] == "burst-busy" end

      destroy = fn _scope, id ->
        send(owner, {:destroyed, id})
        {:ok, %{}}
      end

      results = Sweep.sweep_now(scope(), list: list, now: due_now(), busy?: busy?, destroy: destroy)

      assert :deleted in results
      assert :kept in results
      assert_received {:destroyed, 1}
      refute_received {:destroyed, 2}
    end

    test "no burst boxes in the account is an empty, successful sweep" do
      list = fn _scope -> {:ok, [other_server()]} end
      busy? = fn _scope, _server -> flunk("a non-burst-box server must never be checked") end

      assert Sweep.sweep_now(scope(), list: list, busy?: busy?) == []
    end

    test "a listing failure is logged and swept as empty, rather than raising" do
      list = fn _scope -> {:error, :hetzner_not_configured} end

      log =
        capture_log(fn ->
          assert Sweep.sweep_now(scope(), list: list, busy?: fn _, _ -> true end) == []
        end)

      assert log =~ "could not list servers"
    end

    test "one box's :busy? raising does not stop the others from being checked" do
      owner = self()
      broken = burst_server(%{"id" => 1, "name" => "burst-broken"})
      fine = burst_server(%{"id" => 2, "name" => "burst-fine"})

      list = fn _scope -> {:ok, [broken, fine]} end

      busy? = fn
        _scope, %{"name" => "burst-broken"} -> raise "boom"
        _scope, _server -> false
      end

      destroy = fn _scope, id ->
        send(owner, {:destroyed, id})
        {:ok, %{}}
      end

      log =
        capture_log(fn ->
          results = Sweep.sweep_now(scope(), list: list, now: due_now(), busy?: busy?, destroy: destroy)
          assert Enum.any?(results, &match?({:error, _}, &1))
          assert :deleted in results
        end)

      # The broken box was never destroyed — raising is not the same as
      # proving it idle — but the fine one still was.
      refute_received {:destroyed, 1}
      assert_received {:destroyed, 2}
      assert log =~ "burst-broken"
    end
  end

  describe "role_label/0" do
    test "is the label a burst box is found by" do
      assert Sweep.role_label() == "cms-burst-role"
    end
  end

  describe "the GenServer" do
    test "ticks sweep_now on its own interval" do
      owner = self()
      list = fn _scope -> send(owner, :listed) && {:ok, []} end

      {:ok, pid} =
        Sweep.start_link(
          name: nil,
          scope: scope(),
          interval_ms: 1,
          list: list,
          busy?: fn _, _ -> true end
        )

      assert_receive :listed, 500
      assert_receive :listed, 500
      GenServer.stop(pid)
    end
  end
end
