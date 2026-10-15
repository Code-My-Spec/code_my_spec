defmodule CmsHarness.AnAppLogIsTrimmedNotGrownForeverTest do
  @moduledoc """
  An app instance's log is bounded to one log and one backup. The :4000 app's
  reached 1.4 GB (2026-10-15).
  """
  use ExUnit.Case, async: true

  alias CmsHarness.AppInstance.LogTrim

  @moduletag :tmp_dir

  test "a log past its limit moves to .1 and the running app keeps writing at the start",
       %{tmp_dir: dir} do
    path = Path.join(dir, "app.log")
    {:ok, app} = File.open(path, [:append])
    IO.binwrite(app, String.duplicate("x", 2_000))

    assert LogTrim.trim(path, 1_000) == :trimmed
    assert File.stat!(path <> ".1").size == 2_000

    IO.binwrite(app, "after")
    File.close(app)

    assert File.read!(path) == "after",
           "the app wrote at its old offset, leaving the trimmed log the same size"
  end

  test "a log within its limit is left alone", %{tmp_dir: dir} do
    path = Path.join(dir, "app.log")
    File.write!(path, "short")

    assert LogTrim.trim(path, 1_000) == :ok
    assert File.read!(path) == "short"
    refute File.exists?(path <> ".1")
  end

  test "a missing log is not an error", %{tmp_dir: dir} do
    assert LogTrim.trim(Path.join(dir, "absent.log"), 1_000) == :ok
  end
end
