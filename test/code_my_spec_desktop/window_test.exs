defmodule CodeMySpecDesktop.WindowTest do
  # Not async: sets CMS_BROWSER, which is process-global.
  use ExUnit.Case, async: false

  alias CodeMySpecDesktop.Application, as: DesktopApp
  alias CodeMySpecDesktop.Browser

  setup do
    previous = System.get_env("CMS_BROWSER")
    System.delete_env("CMS_BROWSER")

    on_exit(fn -> restore_env("CMS_BROWSER", previous) end)
  end

  test "the app opens in its own window at the url it is given" do
    assert {Desktop.Window, opts} = DesktopApp.view("http://localhost:4000/app")
    assert opts[:app] == :code_my_spec
    assert opts[:url].() == "http://localhost:4000/app"
  end

  test "CMS_BROWSER falls back to the default browser" do
    System.put_env("CMS_BROWSER", "1")

    assert DesktopApp.view("http://localhost:4000/app") == {Browser, "http://localhost:4000/app"}
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
