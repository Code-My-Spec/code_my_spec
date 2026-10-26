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
  test "the first manifest is delivered before a slow secondary report", %{tmp_dir: root} do
    owner = self()
    project = %{root: root}
    observations = [%{path: "lib/example.ex"}]

    :meck.new(Scanner, [:passthrough, :no_link])
    :meck.new(CmsHarness.Channel, [:passthrough, :no_link])
    :meck.new(CodeMySpec.ExecutionContexts, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(Scanner)
      :meck.unload(CmsHarness.Channel)
      :meck.unload(CodeMySpec.ExecutionContexts)
    end)

    :meck.expect(Scanner, :observe, fn _env, _model -> {:ok, observations} end)

    :meck.expect(CmsHarness.Channel, :deliver_observations, fn ^root, entries ->
      send(owner, {:manifest, entries})
      :ok
    end)

    :meck.expect(CodeMySpec.ExecutionContexts, :cmd, fn _env, "git", _args, _opts ->
      send(owner, {:git_report, self()})

      receive do
        :continue -> {"test-head", 0}
      end
    end)

    task = Task.async(fn -> Sync.run(project, %ReadModel{}) end)
    assert_receive {:manifest, ^observations}, 10_000
    assert_receive {:git_report, worker}, 10_000
    send(worker, :continue)
    assert :ok = Task.await(task, 10_000)
  end
end
