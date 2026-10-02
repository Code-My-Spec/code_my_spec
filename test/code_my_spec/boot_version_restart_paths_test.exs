defmodule CodeMySpec.BootVersionRestartPathsTest do
  @moduledoc """
  The paths a running app cannot hot-reload, which turn a promote's default
  reload into a restart (John, 2026-10-02).
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.BootVersion

  test "deps, config, application.ex, releases, asset deps and the toolchain pin need a restart" do
    needs = [
      "mix.exs",
      "mix.lock",
      "config/config.exs",
      "config/dev/secrets.exs",
      "lib/application.ex",
      "lib/code_my_spec_web/application.ex",
      "lib/cms_harness/supervisor/application.ex",
      "rel/env.sh.eex",
      "assets/package.json",
      "assets/package-lock.json",
      ".tool-versions"
    ]

    assert BootVersion.needs_restart(needs) == needs
  end

  test "ordinary code, tests, migrations and assets reload" do
    assert BootVersion.needs_restart([
             "lib/code_my_spec/promotion.ex",
             "lib/code_my_spec/application_helpers.ex",
             "test/code_my_spec/promotion_test.exs",
             "priv/repo/migrations/20261002131657_x.exs",
             "assets/js/app.js",
             "assets/vendor/package.json",
             "deps/mix.exs",
             "apps/mix.exs",
             "myconfig/dev.exs"
           ]) == []
  end

  test "only the paths that need it are named" do
    assert BootVersion.needs_restart(["lib/a.ex", "config/runtime.exs", "lib/b.ex"]) ==
             ["config/runtime.exs"]
  end

  test "an MCP server's tool registrations need a restart" do
    changed = [
      "lib/code_my_spec/mcp_servers/local_server.ex",
      "lib/code_my_spec/mcp_servers/scriptable_tools.ex",
      "lib/code_my_spec/mcp_servers/tasks/tools/start_task.ex"
    ]

    assert BootVersion.needs_restart(changed) == Enum.take(changed, 2)
  end
end
