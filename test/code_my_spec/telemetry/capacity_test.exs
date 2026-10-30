defmodule CodeMySpec.Telemetry.CapacityTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.ClickHouse.{Capacity, Config, Stack}

  test "room on a shared box permits the full stack" do
    run = fn [_command] -> {"FREE_KIB=4194304\nother-project-web", 0} end
    assert {:ok, %{mode: :full, free_mib: 4096, needed_mib: 2176}} = Capacity.check(run, :full)
  end

  test "low memory refuses full stack with numbers and neighboring apps" do
    run = fn [_command] -> {"FREE_KIB=1048576\nbroken-oaths-web\nmetric-flow-web", 0} end
    assert {:error, reason} = Capacity.check(run, :full)
    assert reason =~ "2176 MiB"
    assert reason =~ "1024 MiB"
    assert reason =~ "broken-oaths-web"
    assert reason =~ "metric-flow-web"
  end

  test "light modes have smaller explicit budgets and capped server configuration" do
    run = fn [_command] -> {"FREE_KIB=2097152\nother-project-web", 0} end
    assert {:ok, %{mode: :capped, needed_mib: 1664}} = Capacity.check(run, :capped)
    assert {:ok, %{mode: :collector_only, needed_mib: 640}} = Capacity.check(run, :collector_only)

    assert Config.server(:capped) =~
             "<max_server_memory_usage>671088640</max_server_memory_usage>"

    refute Config.server(:full) == Config.server(:capped)
  end

  test "capped installation starts ClickHouse with the smaller container limit" do
    run = fn [command] ->
      send(self(), {:remote_command, command})

      table_response(String.contains?(command, "SELECT name FROM system.tables"))
    end

    credentials = %{
      admin: %{username: "admin", password: "secret"},
      writer: %{username: "writer", password: "secret"},
      owner: %{username: "owner", password: "secret"},
      reader: %{username: "reader", password: "secret"}
    }

    assert :ok = Stack.install(run, credentials, ["app-web"], :capped)
    commands = drain_commands([])

    assert Enum.any?(commands, fn command ->
             String.contains?(command, "--name 'cms-clickhouse'") and
               String.contains?(command, "--memory 768m")
           end)
  end

  test "collector-only installation leaves ClickHouse and Vector alone" do
    run = fn [command] ->
      send(self(), {:remote_command, command})
      {"", 0}
    end

    credentials = %{writer: %{username: "writer", password: "secret"}}
    assert :ok = Stack.install(run, credentials, [], :collector_only)
    commands = drain_commands([])
    assert Enum.any?(commands, &String.contains?(&1, "cms-otel-collector"))
    refute Enum.any?(commands, &String.contains?(&1, "--name 'cms-clickhouse'"))
    refute Enum.any?(commands, &String.contains?(&1, "--name 'cms-vector'"))
  end

  defp table_response(true), do: {"otel_logs\notel_traces", 0}
  defp table_response(false), do: {"", 0}

  defp drain_commands(commands) do
    receive do
      {:remote_command, command} -> drain_commands([command | commands])
    after
      0 -> Enum.reverse(commands)
    end
  end
end
