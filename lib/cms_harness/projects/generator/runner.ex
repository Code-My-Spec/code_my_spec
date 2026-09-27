defmodule CmsHarness.Projects.Generator.Runner do
  @moduledoc """
  Seam for the subprocess calls `Generator.run/1` makes — behind a swap, the
  same shape `CmsHarness.Device.Client` gives the announce POST and for the
  same reason.

  The real implementation shells out through several `mix` tasks that take
  real minutes and need a real, correctly-versioned `mix cms.new` archive
  installed on whatever machine runs the suite — unpinned, a spec either
  waits on that or does something unpredictable depending on what happens to
  be on `PATH`. Swapped per test instead, so `Generator`'s own sequencing and
  skip logic can be exercised in milliseconds against a fake that never shells
  out at all.
  """

  @callback cmd(cwd :: String.t(), command :: String.t(), args :: [String.t()]) ::
              {:ok, String.t()} | {:error, term()}

  @doc "The configured runner. Defaults to the real one, via `Environments.cmd/4`."
  @spec impl() :: module()
  def impl, do: Application.get_env(:code_my_spec, :generator_runner, __MODULE__.Real)
end
