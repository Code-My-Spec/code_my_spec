defmodule CmsHarness.Browser.NativeDialogTest do
  @moduledoc """
  A native `alert`/`confirm`/`prompt` never leaves a copy's browser stuck.

  vibium leaves the dialog open and refuses every later call until something
  dismisses it, and an agent told "blocked by an open confirm dialog" has no
  way to learn what opened it. Issue fea9aba9: a `data-confirm` link locked a
  QA agent's turn. `CmsHarnessTest.DialogBrowserTransport` answers the way the
  real binary did when measured.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias CmsHarness.Browser
  alias CmsHarnessTest.DialogBrowserTransport

  setup do
    prior_transport = Application.get_env(:code_my_spec, :harness_mcp_transport)
    prior_exe = Application.get_env(:code_my_spec, :vibium_executable)
    Application.put_env(:code_my_spec, :harness_mcp_transport, DialogBrowserTransport)
    Application.put_env(:code_my_spec, :vibium_executable, "/usr/bin/true")

    on_exit(fn ->
      put_or_delete(:harness_mcp_transport, prior_transport)
      put_or_delete(:vibium_executable, prior_exe)
    end)

    root = "/copies/#{System.unique_integer([:positive])}/copy"
    start_supervised!({Browser.Owner, root: root})
    %{root: root}
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:code_my_spec, key)
  defp put_or_delete(key, v), do: Application.put_env(:code_my_spec, key, v)

  test "the call that raised it says a dialog was dismissed", %{root: root} do
    assert {:error, message} = Browser.call(root, "browser_click", %{"selector" => "#confirm"})

    assert message =~ "input.performActions"
    assert message =~ "dialog dismissed: confirm"
  end

  test "the browser answers the next call", %{root: root} do
    Browser.call(root, "browser_click", %{"selector" => "#confirm"})

    assert Browser.call(root, "browser_get_url", %{}) == {:ok, "http://127.0.0.1:4000/page"}
  end

  test "a call that outlived its deadline has the note carried by the next one",
       %{root: root} do
    assert {:error, _timed_out} =
             Browser.call(root, "browser_click", %{"selector" => "#confirm-slow"})

    assert {:ok, answer} = Browser.call(root, "browser_get_url", %{})
    assert answer =~ "dialog dismissed: confirm"
    assert answer =~ "http://127.0.0.1:4000/page"

    assert Browser.call(root, "browser_get_url", %{}) == {:ok, "http://127.0.0.1:4000/page"},
           "a note is delivered once"
  end

  test "an error with no dialog behind it is returned as it was", %{root: root} do
    assert Browser.call(root, "browser_click", %{"selector" => "#missing"}) ==
             {:error, "failed to click: element not found: #missing"}

    refute "browser_dialog_dismiss" in DialogBrowserTransport.calls(Browser.session(root))
  end
end
