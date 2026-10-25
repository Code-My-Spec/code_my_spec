defmodule CodeMySpec.Provisioning.Tools.EnsureEnvironment do
  @moduledoc "Compatibility delegate; environment tools are owned by Environments."
  @behaviour CodeMySpec.Tools.Tool

  defdelegate name(), to: CodeMySpec.Environments.Tools.EnsureEnvironment
  defdelegate description(), to: CodeMySpec.Environments.Tools.EnsureEnvironment
  defdelegate params(), to: CodeMySpec.Environments.Tools.EnsureEnvironment
  defdelegate call(params, context), to: CodeMySpec.Environments.Tools.EnsureEnvironment
end
