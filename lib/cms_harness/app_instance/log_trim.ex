defmodule CmsHarness.AppInstance.LogTrim do
  @moduledoc """
  Keeps an app instance's log bounded: past its limit its tail is kept as
  `<log>.1` and the log emptied, so one log and a short backup are all it
  ever takes.

  Nothing rotated these, and the :4000 app's log reached 1.4 GB on a machine
  that kept running short of disk (2026-10-15). Emptying it under the running
  app is safe because `just serve >> app.log` opens it in append mode: the
  app's next write lands at the new end, not at its old offset.
  """

  # Kept as `<log>.1`: enough to read back what led up to the trim. Copying the
  # whole log needed as much free space as the log itself, so on a nearly full
  # disk -- the moment this matters -- the copy failed and nothing was trimmed
  # (2026-10-15, 238 MB free beside a 1.6 GB log).
  @kept_bytes 5 * 1024 * 1024

  @doc "Past `max_bytes`, keep the log's tail as `path.1` and empty it."
  @spec trim(Path.t(), non_neg_integer()) :: :ok | :trimmed
  def trim(path, max_bytes) do
    with {:ok, %File.Stat{size: size}} when size > max_bytes <- File.stat(path),
         :ok <- keep_tail(path, size),
         :ok <- File.write(path, "") do
      :trimmed
    else
      _ -> :ok
    end
  end

  defp keep_tail(path, size) do
    kept = min(size, @kept_bytes)

    with {:ok, file} <- File.open(path, [:read, :binary]),
         {:ok, tail} <- :file.pread(file, size - kept, kept),
         :ok <- File.close(file) do
      File.write(path <> ".1", tail)
    end
  end
end
