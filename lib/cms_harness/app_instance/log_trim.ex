defmodule CmsHarness.AppInstance.LogTrim do
  @moduledoc """
  Keeps an app instance's log bounded: past its limit it is copied to
  `<log>.1` and emptied, so one log and one backup are all it ever takes.

  Nothing rotated these, and the :4000 app's log reached 1.4 GB on a machine
  that kept running short of disk (2026-10-15). Emptying it under the running
  app is safe because `just serve >> app.log` opens it in append mode: the
  app's next write lands at the new end, not at its old offset.
  """

  @doc "Copy `path` to `path.1` and empty it once it is larger than `max_bytes`."
  @spec trim(Path.t(), non_neg_integer()) :: :ok | :trimmed
  def trim(path, max_bytes) do
    with {:ok, %File.Stat{size: size}} when size > max_bytes <- File.stat(path),
         :ok <- File.cp(path, path <> ".1"),
         :ok <- File.write(path, "") do
      :trimmed
    else
      _ -> :ok
    end
  end
end
