defmodule CodeMySpec.Requirements.ARequirementNamingNoRoleIsMainsTest do
  @moduledoc """
  a31f1cd6 step 4b: main takes any requirement with no role (John). None is
  role-less today, so the rule is asserted on a definition built here.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleProfile
  alias CodeMySpec.Requirements.RequirementDefinition
  alias CodeMySpec.Requirements.RequirementDefinitionData

  @roleless %RequirementDefinition{name: "nobody_named", role: nil}
  @coding %RequirementDefinition{name: "implementation_file", role: :coding}

  test "a role-less requirement is offered to main and to no other role" do
    assert RequirementDefinitionData.offered_to?(@roleless, :main)

    for role <- RoleProfile.roles() -- [:main] do
      refute RequirementDefinitionData.offered_to?(@roleless, role), inspect(role)
    end
  end

  test "a tagged requirement is still offered to its own role only" do
    assert RequirementDefinitionData.offered_to?(@coding, :coding)
    refute RequirementDefinitionData.offered_to?(@coding, :main)
  end

  test "main is not held on problems; coding is the only role that is (John)" do
    assert RoleProfile.roles_where(:holds_problems?) == [:coding]
  end
end
