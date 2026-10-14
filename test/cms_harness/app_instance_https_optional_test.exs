defmodule CmsHarness.AppInstanceHttpsOptionalTest do
  @moduledoc """
  A main checkout whose `config/dev.exs` declares no HTTPS endpoint at all —
  metric_flow's own shape, `PORT` only, no `HTTPS_PORT` fallback anywhere in
  the file. `Runner.main_ports/1` used to require both, so a real project
  with this shape resolved to `{:cannot_resolve_main_address, root}` on its
  very first restart under `AppInstance` — found live retrying metric_flow
  main through it (harness log: `{:cannot_resolve_main_address,
  "/Volumes/X10 Pro/github/metric_flow"}`, :4070's real cloudflared and app
  left untouched by the refusal).
  """

  # Sync: `app_instance_rig` sets application env.
  use ExUnit.Case, async: false

  import CmsHarnessTest.AppInstanceHelpers

  alias CmsHarnessTest.FakeAppInstanceRunner

  test "main resolves and launches with no HTTPS_PORT of its own" do
    app_instance_rig(main_ports: {4070, nil}, database_exists?: true)

    result = push_app_event_as_main("ensure_app_running")

    assert %{"status" => "ok", "app_status" => "serving"} = result,
           "a main checkout with PORT but no HTTPS_PORT in config/dev.exs " <>
             "should resolve and launch, not be refused as unresolvable. Got: #{inspect(result)}"

    assert [{:launch, [_root, 4070, nil, _database, _log_path, true, _tunnel_held?, _host]}] =
             Enum.filter(FakeAppInstanceRunner.calls(), &match?({:launch, _}, &1))
  end
end
