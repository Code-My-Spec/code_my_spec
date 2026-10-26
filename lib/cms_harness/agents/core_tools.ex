defmodule CmsHarness.Agents.CoreTools do
  @moduledoc """
  The four tools every agent works with: read, write, edit and bash.

  The engine carries them, and Main's working-copy attachments run these same
  modules in the attached copy, so a call behaves the same whoever makes it:
  spilled output, `mix test` routed through the copy's analysis service, the
  same errors (issue 2394520b: same tools, separate transport).
  """

  @modules [
    CmsHarness.Agents.Tools.Read,
    Alloy.Tool.Core.Write,
    Alloy.Tool.Core.Edit,
    CmsHarness.Agents.Tools.Bash
  ]

  @spec modules() :: [module()]
  def modules, do: @modules

  @spec names() :: [String.t()]
  def names, do: Enum.map(@modules, & &1.name())

  @spec fetch(String.t()) :: {:ok, module()} | :error
  def fetch(name) do
    case Enum.find(@modules, &(&1.name() == name)) do
      nil -> :error
      module -> {:ok, module}
    end
  end
end
