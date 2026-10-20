defmodule CodeMySpec.Provisioning.BurstBox.LifecycleTest do
  @moduledoc """
  `:busy?`, `:destroy` and `:now` are all injected, the same reason
  `CodeMySpec.Provisioning.BuilderTest` injects `:create`/`:destroy`: this
  stays a unit test, and every Hetzner call this module could make is a
  closure a caller owns, never a module reference this file could mock
  around instead.
  """
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias CodeMySpec.Provisioning.BurstBox.Lifecycle
  alias CodeMySpec.Users.Scope

  defp scope, do: %Scope{}

  defp server(overrides \\ %{}) do
    Map.merge(
      %{"id" => 7, "name" => "burst-platform", "created" => "2026-08-03T12:00:00Z"},
      overrides
    )
  end

  describe "due_for_check?/2" do
    test "false before minute 55 of the first hour" do
      created = ~U[2026-08-03 12:00:00Z]
      refute Lifecycle.due_for_check?(created, DateTime.add(created, 54, :minute))
    end

    test "true from minute 55 of the first hour" do
      created = ~U[2026-08-03 12:00:00Z]
      assert Lifecycle.due_for_check?(created, DateTime.add(created, 55, :minute))
      assert Lifecycle.due_for_check?(created, DateTime.add(created, 59, :minute))
    end

    test "false again right at the top of the next hour, then true again at its own minute 55" do
      created = ~U[2026-08-03 12:00:00Z]
      refute Lifecycle.due_for_check?(created, DateTime.add(created, 60, :minute))
      refute Lifecycle.due_for_check?(created, DateTime.add(created, 60 + 54, :minute))
      assert Lifecycle.due_for_check?(created, DateTime.add(created, 60 + 55, :minute))
    end

    test "still recurs correctly many hours later" do
      created = ~U[2026-08-03 12:00:00Z]
      assert Lifecycle.due_for_check?(created, DateTime.add(created, 5 * 60 + 56, :minute))
      refute Lifecycle.due_for_check?(created, DateTime.add(created, 5 * 60 + 10, :minute))
    end

    test "now at or before creation is never due" do
      created = ~U[2026-08-03 12:00:00Z]
      refute Lifecycle.due_for_check?(created, created)
      refute Lifecycle.due_for_check?(created, DateTime.add(created, -5, :minute))
    end
  end

  describe "decide/1" do
    test "keeps a busy box" do
      assert Lifecycle.decide(true) == :keep
    end

    test "deletes an idle box" do
      assert Lifecycle.decide(false) == :delete
    end
  end

  describe "check/3 — outside the check window" do
    test "does nothing and never calls :busy? at all" do
      now = fn -> ~U[2026-08-03 12:10:00Z] end

      busy? = fn _scope, _server ->
        flunk("busy? was called outside the check window")
      end

      assert Lifecycle.check(scope(), server(), now: now, busy?: busy?) == :not_due
    end
  end

  describe "check/3 — inside the check window" do
    defp due_now, do: fn -> ~U[2026-08-03 12:55:30Z] end

    test "a busy box is kept, and nothing is destroyed" do
      destroy = fn _scope, _id -> flunk("a busy box must never be destroyed") end
      busy? = fn _scope, _server -> true end

      assert Lifecycle.check(scope(), server(), now: due_now(), busy?: busy?, destroy: destroy) ==
               :kept
    end

    test "an idle box is deleted, by the id the server reports" do
      owner = self()

      destroy = fn _scope, id ->
        send(owner, {:destroyed, id})
        {:ok, %{}}
      end

      busy? = fn _scope, _server -> false end

      assert Lifecycle.check(scope(), server(%{"id" => 99}),
               now: due_now(),
               busy?: busy?,
               destroy: destroy
             ) ==
               :deleted

      assert_received {:destroyed, 99}
    end

    test "the destroy call's own failure is returned, not swallowed, and logged loudly" do
      destroy = fn _scope, _id -> {:error, {:hetzner_error, 423, %{}}} end
      busy? = fn _scope, _server -> false end

      log =
        capture_log(fn ->
          assert Lifecycle.check(scope(), server(),
                   now: due_now(),
                   busy?: busy?,
                   destroy: destroy
                 ) ==
                   {:error, {:hetzner_error, 423, %{}}}
        end)

      assert log =~ "burst-platform"
      assert log =~ "still running and being billed"
    end

    test "reads the server id and name through Hetzner's {\"server\" => ...} envelope too" do
      owner = self()
      wrapped = %{"server" => server(%{"id" => 55, "name" => "burst-wrapped"})}

      destroy = fn _scope, id ->
        send(owner, {:destroyed, id})
        {:ok, %{}}
      end

      busy? = fn _scope, _server -> false end

      assert Lifecycle.check(scope(), wrapped, now: due_now(), busy?: busy?, destroy: destroy) ==
               :deleted

      assert_received {:destroyed, 55}
    end

    test "a server with no readable creation time is left alone, loudly, rather than guessed at" do
      busy? = fn _scope, _server -> flunk("busy? must not be called without a creation time") end

      log =
        capture_log(fn ->
          assert Lifecycle.check(scope(), server(%{"created" => nil}),
                   now: due_now(),
                   busy?: busy?
                 ) ==
                   :not_due
        end)

      assert log =~ "no readable creation time"
    end
  end
end
