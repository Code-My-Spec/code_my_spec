defmodule CmsHarness.CodexCloudReleaseTest do
  use ExUnit.Case, async: true

  test "the cloud installer accepts numeric release pins and rejects development pins" do
    script = Path.expand("../support/codex_cloud_release_test.py", __DIR__)
    {output, status} = System.cmd("python3", ["-B", script], stderr_to_stdout: true)
    assert status == 0, output
  end
end
