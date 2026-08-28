defmodule CodeMySpec.McpServers.ValidatorsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.McpServers.Validators

  describe "devops_project/1" do
    # The whole point of this function existing at all: a devops tool used to
    # accept an explicit project_id parameter and trust it over the
    # connection's own identity — a caller could name (accidentally or not) a
    # different project in the same account than the one this call is
    # actually scoped to. Found live: a caller working through one project's
    # harness got back a different project's own devops checklist through
    # exactly this kind of unchecked parameter. The fix is that no devops
    # tool reads a project_id parameter any more; every one of them asks this
    # instead, and this is the only place "which project" is decided.
    test "returns the project already on the scope" do
      project = %{id: "9b960a44-e39c-4013-9155-56046433c28d", name: "Market My Spec"}
      scope = %{active_project: project}

      assert {:ok, ^project} = Validators.devops_project(scope)
    end

    test "refuses when no project is connected to this call" do
      assert {:error, reason} = Validators.devops_project(%{active_project: nil})
      assert reason =~ "no project is connected"
    end

    test "refuses when the scope carries no project field at all" do
      assert {:error, reason} = Validators.devops_project(%{})
      assert reason =~ "no project is connected"
    end
  end
end
