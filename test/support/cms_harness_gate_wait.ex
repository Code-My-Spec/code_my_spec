defmodule CmsHarnessTest.GateWait do
  @moduledoc "Shared ceiling for event-driven waits in gate spex."

  @doc "Bounds missing events below the normal three-minute spex timeout."
  @spec event_timeout() :: pos_integer()
  def event_timeout, do: :timer.minutes(2)
end
