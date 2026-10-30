defmodule CodeMySpec.Requirements.AStoredQaPlanSettlesQaSetupTest do
  @moduledoc """
  Storing the QA plan settles `qa_setup` on its own. It is a record, not a
  file: a file sync is no longer what re-settles it, so the document store
  announces its own change.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Qa.Documents
  alias CodeMySpec.Requirements.{IncrementalGraph, RequirementGraph}

  @qa_plan """
  # QA plan

  ## App Overview

  The app.

  ## Tools Registry

  A browser.

  ## Seed Strategy

  Fixtures.
  """

  test "a stored QA plan satisfies qa_setup with no sync" do
    scope = full_scope_fixture()
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    :ok = IncrementalGraph.settle(scope.active_project_id)
    refute satisfied?(scope, "qa_setup"), "the premise did not hold"

    {:ok, _} = Documents.put(scope, "qa_plan", nil, @qa_plan)
    :ok = IncrementalGraph.settle(scope.active_project_id)

    assert satisfied?(scope, "qa_setup")
  end

  defp satisfied?(scope, name) do
    {nodes, _edges} = RequirementGraph.served_graph(scope, RequirementGraph.read_context(scope))
    Enum.find(nodes, &(&1.name == name)).satisfied
  end
end
