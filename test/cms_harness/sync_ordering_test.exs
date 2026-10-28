defmodule CmsHarness.SyncOrderingTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Sync
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel

  @tag :tmp_dir
  test "a rescan waits for the preceding scan instead of overtaking it", %{tmp_dir: root} do
    project = %{root: root}
    owner = self()
    start_supervised!({Task.Supervisor, name: Sync.task_supervisor(root)})
    :meck.new(Scanner, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Scanner) end)

    :meck.expect(Scanner, :observe, fn _environment, model ->
      send(owner, {:scan_started, self(), model.strict?})

      receive do
        :finish -> send(owner, {:scan_finished, model.strict?})
      end

      {:ok, []}
    end)

    assert :ok = Sync.start(project, %ReadModel{strict?: true})
    assert_receive {:scan_started, first, true}
    assert :ok = Sync.start(project, %ReadModel{strict?: false})
    refute_receive {:scan_started, _, false}

    send(first, :finish)
    assert_receive {:scan_finished, true}
    assert_receive {:scan_started, second, false}
    send(second, :finish)
    assert_receive {:scan_finished, false}
  end

  @tag :tmp_dir
  test "requests made while a scan waits are absorbed into it", %{tmp_dir: root} do
    project = %{root: root}
    owner = self()
    start_supervised!({Task.Supervisor, name: Sync.task_supervisor(root)})
    :meck.new(Scanner, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Scanner) end)

    :meck.expect(Scanner, :observe, fn _environment, _model ->
      send(owner, {:scan_started, self()})

      receive do
        :finish -> :ok
      end

      {:ok, []}
    end)

    assert :ok = Sync.start(project, %ReadModel{})
    assert_receive {:scan_started, first}

    # The first is scanning: the next request waits, the other two are absorbed.
    for _ <- 1..3, do: assert(:ok = Sync.start(project, %ReadModel{}))

    send(first, :finish)
    assert_receive {:scan_started, second}
    send(second, :finish)
    refute_receive {:scan_started, _}, 500
  end
end
