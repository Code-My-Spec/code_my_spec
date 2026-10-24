defmodule CodeMySpecDesktop.ShellTest do
  use ExUnit.Case, async: true

  defmodule Runtime do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}
  end

  test "starts the runtime before opening /app without a bootstrap listener" do
    parent = self()

    view = fn url ->
      {Task,
       fn ->
         send(parent, {:opened, url})

         receive do
           :stop -> :ok
         end
       end}
    end

    supervisor =
      start_supervised!(
        {CodeMySpecDesktop.Application.Shell,
         runtime: Runtime, view: view, app_url: "http://127.0.0.1:47400/app"}
      )

    assert_receive {:opened, "http://127.0.0.1:47400/app"}
    assert [{Task, _, _, _}, {Runtime, runtime, _, _}] = Supervisor.which_children(supervisor)
    assert Process.alive?(runtime)
  end

  test "runtime failure prevents opening an unusable window" do
    parent = self()
    view = fn url -> {Task, fn -> send(parent, {:opened, url}) end} end

    assert {:error, _} =
             start_supervised(
               {CodeMySpecDesktop.Application.Shell,
                runtime: CodeMySpecTest.UnavailableDesktopRuntime, view: view, app_url: "/app"}
             )

    refute_receive {:opened, _}
  end
end
