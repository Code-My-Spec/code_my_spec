defmodule CmsHarness.Web.DashboardStatusControllerTest do
  use CmsHarnessTest.ConnCase, async: false

  alias CmsHarness.AnalysisSlots
  alias CmsHarnessTest.{AnalysisResults, BlockingProject, FakeServer}

  test "dashboard distinguishes a slot wait from analyzer execution" do
    FakeServer.start()
    project = project_dir()
    marker = BlockingProject.make_blocking(project.root)
    on_exit(fn -> stop_project(project.root) end)
    on_exit(fn -> BlockingProject.unblock(marker) end)

    holders =
      for _ <- 1..AnalysisSlots.limit() do
        holder = spawn(fn -> hold_slot() end)
        on_exit(fn -> Process.exit(holder, :kill) end)
        holder
      end

    await(fn -> AnalysisSlots.in_use() == AnalysisSlots.limit() end)
    serve(project.root)
    assert AnalysisResults.await_connected(project.root)
    FakeServer.request_analysis([%{"run_id" => 901, "source" => "compiler", "args" => []}])
    await(fn -> AnalysisSlots.waiting() > 0 end)

    waiting = dashboard()
    queue = project_queue(waiting, project.root)
    assert queue["running"] == nil
    assert [%{"run_id" => 901, "source" => "compiler"}] = queue["queued"]
    assert waiting["slots"]["waiting"] > 0

    Enum.each(holders, &Process.exit(&1, :kill))
    BlockingProject.await_started(project.root)
    running = project_queue(dashboard(), project.root)
    assert %{"run_id" => 901, "source" => "compiler"} = running["running"]
    assert running["queued"] == []

    BlockingProject.unblock(marker)
    assert %{"status" => "ok"} = AnalysisResults.await_result(901)
  end

  defp hold_slot do
    :ok = AnalysisSlots.acquire()
    Process.sleep(:infinity)
  end

  defp dashboard, do: build_conn() |> get("/dashboard-status") |> json_response(200)

  defp project_queue(body, root) do
    body["projects"] |> Enum.find(&(&1["root"] == root)) |> Map.fetch!("queue")
  end

  defp await(check), do: await(check, 200)
  defp await(check, attempts), do: await_result(check.(), check, attempts)
  defp await_result(true, _check, _attempts), do: :ok
  defp await_result(false, _check, 0), do: flunk("slot state did not arrive")

  defp await_result(false, check, attempts) do
    Process.sleep(10)
    await(check, attempts - 1)
  end
end
