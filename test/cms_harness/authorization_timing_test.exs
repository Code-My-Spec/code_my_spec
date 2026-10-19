defmodule CmsHarness.AuthorizationTimingTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Authorization

  test "authorized harness checks again at the configured interval" do
    dir = CodeMySpec.TempFile.dir("authorization-timing")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    server = "https://authorization-timing.example.test"
    hash = :crypto.hash(:sha256, server) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(dir, "harness_oauth_#{hash}.json"),
      Jason.encode!(%{
        access_token: "valid-access",
        refresh_token: "valid-refresh",
        expires_at: System.system_time(:second) + 7200
      })
    )

    {:ok, state, {:continue, :check}} =
      Authorization.init(
        server_url: server,
        oauth_opts: [state_dir: dir],
        check_interval_seconds: 1
      )

    {:noreply, authorized} =
      Authorization.handle_continue(:check, %{state | announced: true})

    assert authorized.phase == :authorized
    timer = authorized.timer
    assert_receive {:timeout, ^timer, :check}, 2000

    {:noreply, checked} = Authorization.handle_info({:timeout, timer, :check}, authorized)
    assert checked.phase == :authorized
    next_timer = checked.timer
    assert_receive {:timeout, ^next_timer, :check}, 2000
  end
end
