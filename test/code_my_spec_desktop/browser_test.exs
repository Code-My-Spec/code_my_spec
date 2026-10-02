defmodule CodeMySpecDesktop.BrowserTest do
  # Not async: sets CMS_NO_BROWSER, which is process-global.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias CodeMySpecDesktop.Browser

  test "each OS's opener" do
    url = "http://localhost:4000"
    assert Browser.command({:unix, :darwin}, url) == {"open", [url]}
    assert Browser.command({:unix, :linux}, url) == {"xdg-open", [url]}
    assert Browser.command({:win32, :nt}, url) == {"cmd", ["/c", "start", "", url]}
  end

  test "CMS_NO_BROWSER skips opening" do
    previous = System.get_env("CMS_NO_BROWSER")
    level = Logger.level()
    System.put_env("CMS_NO_BROWSER", "1")
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: level)
      restore_env("CMS_NO_BROWSER", previous)
    end)

    log = capture_log(fn -> assert Browser.open("http://x") == :ignore end)
    assert log =~ "CMS_NO_BROWSER set, not opening http://x"
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
