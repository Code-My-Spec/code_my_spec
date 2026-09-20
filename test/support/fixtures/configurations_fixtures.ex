defmodule CodeMySpec.ConfigurationsFixtures do
  @moduledoc "Fixtures for a project's local quality-gate configuration."
  alias CodeMySpec.Configurations

  @doc "Ensure the project has its default analyzer and deployment configuration."
  def ensure_configuration!(scope) do
    Configurations.get_or_create(scope)
    scope
  end
end
