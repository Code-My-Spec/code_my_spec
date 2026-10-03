defmodule CmsHarness.ConfigTest do
  @moduledoc """
  Where the harness is pointed.

  Five layers, each only there to say something more specific than the one
  below: this call and this target (`:harness_server_url_override`), this run
  (`CMS_SERVER_URL`), this install (`:harness_server_url`), this application
  (`:base_url`), this build (`default_server_url/0`).

  The order is the whole point. A harness aimed at the wrong server does not
  fail loudly — it connects to nothing and looks exactly like a harness with
  nothing to do.
  """

  # Sync, for two reasons that would each be enough. It sets OS environment
  # variables, which are node-global; and it writes `:base_url` and
  # `:harness_server_url` into application env, the latter shared with
  # `web/mcp_controller_test` and `web/permission_controller_test`.
  use ExUnit.Case, async: false

  alias CmsHarness.Config

  setup do
    previous = %{
      env: System.get_env("CMS_SERVER_URL"),
      override: Application.get_env(:code_my_spec, :harness_server_url_override),
      harness: Application.get_env(:code_my_spec, :harness_server_url),
      base: Application.get_env(:code_my_spec, :base_url)
    }

    System.delete_env("CMS_SERVER_URL")
    Application.delete_env(:code_my_spec, :harness_server_url_override)
    Application.delete_env(:code_my_spec, :harness_server_url)
    Application.delete_env(:code_my_spec, :base_url)

    on_exit(fn ->
      restore_env("CMS_SERVER_URL", previous.env)
      restore_app(:harness_server_url_override, previous.override)
      restore_app(:harness_server_url, previous.harness)
      restore_app(:base_url, previous.base)
    end)

    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp restore_app(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp restore_app(key, value), do: Application.put_env(:code_my_spec, key, value)

  describe "server_url/0 resolution order" do
    test "the environment wins over everything compiled in" do
      System.put_env("CMS_SERVER_URL", "http://localhost:4000")
      Application.put_env(:code_my_spec, :harness_server_url, "https://install.example")
      Application.put_env(:code_my_spec, :base_url, "https://app.example")

      assert Config.server_url() == "http://localhost:4000",
             "`just harness` aims a laptop at its own dev server this way; nothing " <>
               "compiled in may override what the operator just typed"
    end

    # The one thing above the variable, and the reason it is above rather than
    # below: `CMS_SERVER_URL` describes the shell, and `--server-url` describes
    # the root being onboarded. Onboarding a sibling repo from a shell aimed at
    # this build's server is exactly the case a6d07cf3 reported — it minted an
    # id into a database the daemon serving that repo had never seen, and every
    # artifact looked right.
    test "an onboard override beats the environment, because it is about the target" do
      System.put_env("CMS_SERVER_URL", "http://localhost:4000")

      Application.put_env(
        :code_my_spec,
        :harness_server_url_override,
        "https://codemyspec.com"
      )

      assert Config.server_url() == "https://codemyspec.com",
             "a checkout onboarded with an explicit --server-url was minted against " <>
               "the shell's server instead. The id lands where nothing that serves " <>
               "that checkout will ever look for it, and the run reports success."
    end

    test "an install override beats the application's own server" do
      Application.put_env(:code_my_spec, :harness_server_url, "https://install.example")
      Application.put_env(:code_my_spec, :base_url, "https://app.example")

      assert Config.server_url() == "https://install.example"
    end

    test "the application's server is used when the harness has no opinion" do
      Application.put_env(:code_my_spec, :base_url, "https://app.example")

      assert Config.server_url() == "https://app.example",
             "the harness belongs to the same server as the rest of the application " <>
               "unless it is told otherwise"
    end

    test "with nothing configured it falls to this build's server" do
      assert Config.server_url() == Config.default_server_url()
    end
  end

  describe "default_server_url/0" do
    test "names a real server rather than a laptop" do
      url = Config.default_server_url()

      assert url =~ ~r{\Ahttps?://}

      assert url in [
               "https://codemyspec.com",
               "https://dev.codemyspec.com",
               "http://localhost:4000"
             ],
             "the harness env defaults to codemyspec.com (CMS_SERVER_URL overrides it " <>
               "at runtime) and only an unconfigured env falls to localhost. It was " <>
               "a flat localhost, which is right for a laptop and silently wrong for " <>
               "every release."
    end

    test "is read at runtime, so one build serves dev and the release" do
      previous = Application.get_env(:code_my_spec, :harness_default_server_url)
      Application.put_env(:code_my_spec, :harness_default_server_url, "https://runtime.example")

      on_exit(fn -> restore_app(:harness_default_server_url, previous) end)

      assert Config.default_server_url() == "https://runtime.example"
    end

    test "the test build points at localhost" do
      assert Config.default_server_url() == "http://localhost:4000"
    end
  end

  # `CmsHarness.Device`'s own file, `device.json`, lives here. Getting this
  # wrong for a `Runner.Local`-booted workspace is what let it silently
  # inherit the box's own persistent harness's device identity — and with
  # it every working copy the server believed that device served. Measured
  # live, 2026-09-21: a fresh workspace's harness retrying against a dozen
  # unrelated worktrees it had never touched, because its device.json was
  # the same file its box's real, long-running harness already held.
  describe "local_state_dir/0" do
    setup do
      previous = System.get_env("CMS_PROJECT_DIR")
      on_exit(fn -> restore_env("CMS_PROJECT_DIR", previous) end)
      :ok
    end

    test "a laptop with no project dir named gets the shared install directory" do
      System.delete_env("CMS_PROJECT_DIR")

      assert Config.local_state_dir() == Path.expand("~/.codemyspec")
    end

    test "a workspace named by CMS_PROJECT_DIR gets its own directory instead" do
      System.put_env("CMS_PROJECT_DIR", "/tmp/cms-workspace-abc123/widget_tracker")

      assert Config.local_state_dir() == "/tmp/cms-workspace-abc123",
             """
             One directory up from CMS_PROJECT_DIR, which Workspaces.instance_env/1
             already minted uniquely per instance — not the shared ~/.codemyspec every
             other harness on this box also reads and writes.
             """
    end
  end
end
