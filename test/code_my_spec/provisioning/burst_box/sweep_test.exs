defmodule CodeMySpec.Provisioning.BurstBox.SweepTest do
  @moduledoc """
  `:list` is injected the same reason `CodeMySpec.Provisioning.Builder`'s own
  `reap_orphaned_builders/2` injects `:list` — this is a unit test over the
  "which boxes get a check at all" and "one bad box must not sink the sweep"
  logic, not a round trip to Hetzner.
  """
  use CodeMySpecTest.DataCase, async: true

  import ExUnit.CaptureLog
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.ProvisioningPlan
  alias CodeMySpec.ProvisioningPlan.Step
  alias CodeMySpec.Provisioning.Builder
  alias CodeMySpec.Provisioning.BurstBox.Sweep
  alias CodeMySpec.Users.Scope

  defp scope, do: %Scope{}

  # Keep unrelated runs and setup rows in other async tests from changing
  # which servers these unit tests examine. Explicit gate options still win.
  defp sweep_now(scope, opts) do
    Sweep.sweep_now(
      scope,
      Keyword.merge(
        [run_in_flight?: fn -> false end, setup_pending?: fn -> false end],
        opts
      )
    )
  end

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
    Map.merge(
      %{"id" => 1, "name" => "builder-abc123", "created" => "2026-08-03T12:00:00Z"},
      overrides
    )
  end

  # Carries only `Builder.bootstrap_role_label/0` — a server whose snapshot
  # outcome `Builder.finish_snapshot/8` left unconfirmed (story 877/992
  # follow-on: that used to be destroyed unconditionally, which is how a
  # real snapshot got lost mid-write).
  defp bootstrap_server(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => 9,
        "name" => "cms-burst-bootstrap-arm-123",
        "created" => "2026-08-03T12:00:00Z",
        "labels" => %{Builder.bootstrap_role_label() => "arm"}
      },
      overrides
    )
  end

  defp no_image_yet, do: fn _scope, _opts -> {:ok, []} end
  defp image_available, do: fn _scope, _opts -> {:ok, [%{"id" => 1, "status" => "available"}]} end

  describe "sweep_now/2" do
    test "only ever checks servers carrying the burst-box label" do
      list = fn _scope -> {:ok, [burst_server(), other_server()]} end
      busy? = fn _scope, server -> server["id"] == 7 end

      assert [result] = sweep_now(scope(), list: list, now: due_now(), busy?: busy?)
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

      results =
        sweep_now(scope(), list: list, now: due_now(), busy?: busy?, destroy: destroy)

      assert :deleted in results
      assert :kept in results
      assert_received {:destroyed, 1}
      refute_received {:destroyed, 2}
    end

    test "never checks app servers even if they carry a burst label" do
      servers = [
        burst_server(%{"id" => 1, "name" => "fuellytics"}),
        burst_server(%{"id" => 2, "name" => "fuellytics-prod"})
      ]

      busy? = fn _, _ -> flunk("app server must never be checked") end
      assert [] = sweep_now(scope(), list: fn _ -> {:ok, servers} end, busy?: busy?)
    end

    test "never checks an unlabelled box even when its name resembles a burst box" do
      servers = [
        burst_server(%{"id" => 1, "name" => "burst-platform", "labels" => %{}}),
        burst_server(%{"id" => 2, "name" => "cms-burst-bootstrap-old", "labels" => %{}})
      ]

      busy? = fn _, _ -> flunk("unlabelled server must never be checked") end
      assert [] = sweep_now(scope(), list: fn _ -> {:ok, servers} end, busy?: busy?)
    end

    test "no burst boxes in the account is an empty, successful sweep" do
      list = fn _scope -> {:ok, [other_server()]} end
      busy? = fn _scope, _server -> flunk("a non-burst-box server must never be checked") end

      assert sweep_now(scope(), list: list, busy?: busy?) == []
    end

    test "a listing failure is logged and swept as empty, rather than raising" do
      list = fn _scope -> {:error, :hetzner_not_configured} end

      log =
        capture_log(fn ->
          assert sweep_now(scope(), list: list, busy?: fn _, _ -> true end) == []
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
          results =
            sweep_now(scope(), list: list, now: due_now(), busy?: busy?, destroy: destroy)

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

  describe "sweep_now/2 — bootstrap servers (story 877/992 follow-on)" do
    test "leaves a bootstrap server alone while its snapshot is still plausibly in flight" do
      list = fn _scope -> {:ok, [bootstrap_server()]} end
      busy? = fn _scope, _server -> flunk("a bootstrap server has no busy? check") end

      assert [:not_due] =
               sweep_now(scope(),
                 list: list,
                 busy?: busy?,
                 list_images: no_image_yet(),
                 now: fn -> ~U[2026-08-03 12:05:00Z] end
               )
    end

    test "reaps a bootstrap server once its snapshot is confirmed available" do
      owner = self()
      list = fn _scope -> {:ok, [bootstrap_server()]} end

      destroy = fn _scope, id ->
        send(owner, {:destroyed, id})
        {:ok, %{}}
      end

      assert [:reaped] =
               sweep_now(scope(),
                 list: list,
                 busy?: fn _, _ -> false end,
                 list_images: image_available(),
                 destroy: destroy,
                 now: fn -> ~U[2026-08-03 12:05:00Z] end
               )

      assert_received {:destroyed, 9}
    end

    test "reaps a stale bootstrap server whose snapshot never showed up" do
      owner = self()
      list = fn _scope -> {:ok, [bootstrap_server()]} end

      destroy = fn _scope, id ->
        send(owner, {:destroyed, id})
        {:ok, %{}}
      end

      assert [:reaped] =
               sweep_now(scope(),
                 list: list,
                 busy?: fn _, _ -> false end,
                 list_images: no_image_yet(),
                 destroy: destroy,
                 bootstrap_max_age_minutes: 60,
                 # created at 12:00:00Z — two hours later is well past the
                 # default (and this override's) staleness window.
                 now: fn -> ~U[2026-08-03 14:00:00Z] end
               )

      assert_received {:destroyed, 9}
    end

    test "a burst box and a bootstrap server in the same sweep are judged by their own, separate rules" do
      burst = burst_server()
      bootstrap = bootstrap_server()
      list = fn _scope -> {:ok, [burst, bootstrap]} end

      results =
        sweep_now(scope(),
          list: list,
          busy?: fn _, _ -> true end,
          list_images: no_image_yet(),
          now: fn -> ~U[2026-08-03 12:55:30Z] end
        )

      assert :kept in results
      assert :not_due in results
    end
  end

  describe "role_label/0" do
    test "is the label a burst box is found by" do
      assert Sweep.role_label() == "cms-burst-role"
    end
  end

  describe "legacy builder reaping" do
    defp legacy_builder(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => 21,
          "name" => "builder-2633473a5e14",
          "created" => "2026-08-01T00:00:00Z",
          "labels" => %{Sweep.legacy_builder_role_label() => "true"}
        },
        overrides
      )
    end

    defp reaper_opts(servers, owner, extra \\ []) do
      Keyword.merge(
        [
          list: fn _scope -> {:ok, servers} end,
          now: due_now(),
          busy?: fn _, _ -> true end,
          run_in_flight?: fn -> false end,
          reap_legacy_builders: true,
          destroy: fn _scope, id ->
            send(owner, {:destroyed, id})
            {:ok, %{}}
          end
        ],
        extra
      )
    end

    test "deletes a builder-<12 hex> box past the age cutoff" do
      assert [:reaped] = sweep_now(scope(), reaper_opts([legacy_builder()], self()))
      assert_received {:destroyed, 21}
    end

    test "never deletes an unlabelled legacy builder" do
      unlabelled = legacy_builder(%{"labels" => %{}})
      assert [] = sweep_now(scope(), reaper_opts([unlabelled], self()))
      refute_received {:destroyed, _}
    end

    test "leaves a young builder alone" do
      young = legacy_builder(%{"created" => "2026-08-03T12:30:00Z"})
      assert [:not_due] = sweep_now(scope(), reaper_opts([young], self()))
      refute_received {:destroyed, _}
    end

    test "is off unless asked for" do
      opts = reaper_opts([legacy_builder()], self(), reap_legacy_builders: false)
      assert [] = sweep_now(scope(), opts)
      refute_received {:destroyed, _}
    end

    test "never touches an app server, whatever its age or name" do
      servers = [
        legacy_builder(%{"id" => 1, "name" => "fuellytics-prod"}),
        legacy_builder(%{"id" => 2, "name" => "fuellytics"}),
        legacy_builder(%{"id" => 3, "name" => "builder-prod"}),
        legacy_builder(%{"id" => 4, "name" => "builder-2633473a5e14-extra"})
      ]

      assert [] = sweep_now(scope(), reaper_opts(servers, self()))
      refute_received {:destroyed, _}
    end

    test "leaves a builder that carries a burst or bootstrap label to its own path" do
      burst_labelled = legacy_builder(%{"labels" => %{Sweep.role_label() => "true"}})

      assert [:kept] = sweep_now(scope(), reaper_opts([burst_labelled], self()))
      refute_received {:destroyed, _}
    end
  end

  describe "a provisioning run in flight" do
    test "deletes nothing and lists nothing" do
      owner = self()

      opts = [
        list: fn _scope -> send(owner, :listed) && {:ok, [burst_server()]} end,
        now: due_now(),
        busy?: fn _, _ -> false end,
        run_in_flight?: fn -> true end,
        reap_legacy_builders: true,
        destroy: fn _scope, id -> send(owner, {:destroyed, id}) && {:ok, %{}} end
      ]

      assert [] = sweep_now(scope(), opts)
      refute_received :listed
      refute_received {:destroyed, _}
    end

    test "a setup paused between steps keeps the builder and avoids listing" do
      owner = self()

      opts = [
        list: fn _scope -> send(owner, :listed) && {:ok, [burst_server()]} end,
        run_in_flight?: fn -> false end,
        setup_pending?: fn -> true end,
        destroy: fn _scope, id -> send(owner, {:destroyed, id}) && {:ok, %{}} end
      ]

      assert [] = sweep_now(scope(), opts)
      refute_received :listed
      refute_received {:destroyed, _}
    end

    test "persisted setup rows retain the burst box until the server step completes" do
      scope = provisioning_scope_fixture()
      refute ProvisioningPlan.server_setup_pending?()

      Repo.insert!(
        Step.changeset(%Step{}, %{
          project_id: scope.active_project_id,
          key: :repository,
          state: :done,
          position: 0
        })
      )

      assert ProvisioningPlan.server_setup_pending?()

      Repo.insert!(
        Step.changeset(%Step{}, %{
          project_id: scope.active_project_id,
          key: :server,
          state: :done,
          position: 1
        })
      )

      refute ProvisioningPlan.server_setup_pending?()

      Repo.insert!(
        Step.changeset(%Step{}, %{
          project_id: scope.active_project_id,
          key: :secrets,
          state: :running,
          environment: "uat",
          position: 2
        })
      )

      refute ProvisioningPlan.server_setup_pending?()
    end

    test "RunLock.any_in_flight?/0 sees a held lock" do
      project_id = Ecto.UUID.generate()

      test_pid = self()

      holder =
        spawn_link(fn ->
          CodeMySpec.Provisioning.RunLock.with_lock(project_id, fn ->
            send(test_pid, :held)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :held, 500
      assert CodeMySpec.Provisioning.RunLock.any_in_flight?()
      send(holder, :release)
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
          setup_pending?: fn -> false end,
          busy?: fn _, _ -> true end
        )

      assert_receive :listed, 500
      assert_receive :listed, 500
      GenServer.stop(pid)
    end
  end
end
