defmodule CmsHarness.ConfigTest do
  @moduledoc """
  Where the harness is pointed.

  Four layers, each only there to say something more specific than the one
  below: this run (`CMS_SERVER_URL`), this install (`:harness_server_url`), this
  application (`:base_url`), this build (`default_server_url/0`).

  The order is the whole point. A harness aimed at the wrong server does not
  fail loudly — it connects to nothing and looks exactly like a harness with
  nothing to do.
  """

  use ExUnit.Case, async: false

  alias CmsHarness.Config

  setup do
    previous = %{
      env: System.get_env("CMS_SERVER_URL"),
      harness: Application.get_env(:code_my_spec, :harness_server_url),
      base: Application.get_env(:code_my_spec, :base_url)
    }

    System.delete_env("CMS_SERVER_URL")
    Application.delete_env(:code_my_spec, :harness_server_url)
    Application.delete_env(:code_my_spec, :base_url)

    on_exit(fn ->
      restore_env("CMS_SERVER_URL", previous.env)
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
    test "the environment wins over everything" do
      System.put_env("CMS_SERVER_URL", "http://localhost:4000")
      Application.put_env(:code_my_spec, :harness_server_url, "https://install.example")
      Application.put_env(:code_my_spec, :base_url, "https://app.example")

      assert Config.server_url() == "http://localhost:4000",
             "`just harness` aims a laptop at its own dev server this way; nothing " <>
               "compiled in may override what the operator just typed"
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
             "the default is per build environment — prod to codemyspec.com, the " <>
               "cli/sprite builds to dev, and only a local build to localhost. It was " <>
               "a flat localhost, which is right for a laptop and silently wrong for " <>
               "every release."
    end

    test "the test build points at localhost" do
      assert Config.default_server_url() == "http://localhost:4000"
    end
  end
end
