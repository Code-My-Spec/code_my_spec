defmodule CodeMySpec.Requirements.CheckerBehaviour do
  @moduledoc """
  Behaviour for requirement checkers that evaluate entity satisfaction.
  """

  alias CodeMySpec.Requirements.Requirement
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Users.Scope

  @callback check(Scope.t(), RequirementDefinition.t(), entity :: term(), keyword()) ::
              Requirement.requirement_attrs()
end
