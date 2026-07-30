defmodule CodeMySpec.ConfigurationsFixtures do
  @moduledoc """
  Fixtures for a project's local quality-gate configuration.
  """

  alias CodeMySpec.Configurations

  @doc """
  Turns the three requirement toggles on.

  A fresh project defaults them off — it writes BDD spex and code and nothing
  else. Tests about the *shape of the requirement graph* need the full chain
  (spec → review → test → implementation) to have anything to assert about, so
  they ask for it here rather than inheriting it.

  Being explicit is the point. When these toggles were on by default, every one
  of those tests silently depended on that, and flipping the default turned
  twenty-one of them red at once without any of them mentioning a
  configuration. A test that needs the full chain should say so.
  """
  @spec require_all!(CodeMySpec.Users.Scope.t()) :: CodeMySpec.Users.Scope.t()
  def require_all!(scope) do
    {:ok, _config} =
      Configurations.update(scope, %{
        require_specs: true,
        require_reviews: true,
        require_unit_tests: true
      })

    scope
  end
end
