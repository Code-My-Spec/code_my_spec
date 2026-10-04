defmodule CmsHarness.AppInstance.Runner.LocalServeLogTest do
  @moduledoc """
  c531da1e: a restart launched `just serve > app.log` while the old process,
  on its way out, still held the log open without `O_APPEND`. The truncate
  left its last write — "Interrupted by SIGTERM" — at its old offset, behind
  megabytes of NULs, and that line read as the new app being killed
  (181d5fdd) though the new app came up and served.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance.Runner.Local

  test "the serve line appends to the app log rather than truncating it" do
    log = "/home/x/.codemyspec/app-instances/abc/app.log"
    cmd = Local.serve_command("PORT=4100 DATABASE_NAME=db", log)

    assert cmd =~ ">> #{log} 2>&1",
           "truncating the log under the previous process leaves a NUL-filled hole"

    refute cmd =~ ~r/[^>]> #{Regex.escape(log)}/
  end
end
