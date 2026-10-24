defmodule CodeMySpec.Environments.Tools do
  @moduledoc "Agent tools for durable project destinations and runtime assignment."
  use Boundary,
    top_level?: true,
    deps: [CodeMySpec.Environments, CodeMySpec.AppInstances, CodeMySpec.Tools]

  def all do
    [
      CodeMySpec.Environments.Tools.ListEnvironments,
      CodeMySpec.Environments.Tools.AssignAppInstanceEnvironment
    ]
  end
end
