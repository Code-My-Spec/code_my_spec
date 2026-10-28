defmodule CmsHarness.SopsKeySocketScopeTest do
  use ExUnit.Case, async: false

  test "ExUnit binds a socket private to its own BEAM" do
    expected =
      Path.join([System.tmp_dir!(), "cms-sops-key-sockets", "key-#{System.pid()}.sock"])

    assert System.get_env("CMS_SOPS_KEY_SOCKET_PATH") == expected
    assert CmsHarness.SopsKeySocket.path() == expected

    if elem(:os.type(), 0) != :win32 do
      assert File.exists?(expected)
    end
  end
end
