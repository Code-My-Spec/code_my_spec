defmodule CodeMySpec.McpServers.ToolRegistry do
  @moduledoc """
  The components both servers register, for `Agents.ToolIndex`.

  `Agents` cannot read `LocalServer` or `ScriptableTools` itself: this boundary
  depends on `Agents`, so the call would point up. The layer that knows the
  servers builds the list and hands it down, as it does for `CodeMode.Catalog`.
  """

  alias CodeMySpec.Agents.ToolIndex
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.ScriptableTools

  @spec registry() :: ToolIndex.registry()
  def registry do
    %{direct: LocalServer.__components__(), scriptable: ScriptableTools.registrations()}
  end
end
