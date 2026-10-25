defmodule CodeMySpec.AppRole do
  @moduledoc """
  Whether this app is main's or a working copy's own.

  A copy's app runs on a clone of main's database, so it holds main's open
  promotions, devices and tunnels as rows. Acting on them from there would
  publish, sync or connect beside main, so whatever acts on shared state
  outside this app asks here first.

  Set by `AppInstance.Runner.Local` (`CMS_MAIN_COPY`); unset, as under a plain
  `mix phx.server`, reads as main.
  """

  use Boundary, top_level?: true, deps: []

  @doc "True unless this app was started as a working copy's own."
  @spec main_copy?() :: boolean()
  def main_copy?, do: System.get_env("CMS_MAIN_COPY") != "false"
end
