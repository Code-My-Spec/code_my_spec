defmodule CmsHarness.SopsKeySocketScopeTest do
  use ExUnit.Case, async: false

  test "ExUnit binds a socket private to its own BEAM" do
    expected =
      Path.join([System.tmp_dir!(), "cms-sops-key-sockets", "key-#{System.pid()}.sock"])

    assert System.get_env("CMS_SOPS_KEY_SOCKET_PATH") == expected
    assert CmsHarness.SopsKeySocket.path() == expected

    assert elem(:os.type(), 0) == :win32 or File.exists?(expected)
  end
end
