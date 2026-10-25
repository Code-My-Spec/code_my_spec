defmodule CodeMySpecTest.SuspendedProjector do
  @moduledoc "Runs assertions while the graph writer is paused, restoring it even on failure."

  def while_suspended(pid, fun) do
    :ok = :sys.suspend(pid)

    try do
      fun.()
    after
      :sys.resume(pid)
    end
  end
end
