defmodule CodeMySpec.Agents.Tools do
  @moduledoc "The agent tools an agent calls, for `CodeMySpec.ToolLibrary`."

  def all, do: [__MODULE__.RejectOffer]
end
