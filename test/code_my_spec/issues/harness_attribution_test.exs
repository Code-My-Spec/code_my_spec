defmodule CodeMySpec.Issues.HarnessAttributionTest do
  @moduledoc """
  An issue records the working copy it was raised from.

  Files, problems and analysis runs all carry `harness_id`; issues did not. So
  the first question anyone asks about a report — "is this my checkout or
  another agent's?" — was answerable only from prose the author happened to
  type into the body.

  It was asked in earnest, about two spex failures blocking a stop, and took a
  query against `problems` to settle. The marker issue raised to verify
  framework intake (9c8ade27) names the acceptance criterion outright: scope,
  severity, and working copy attached. Two of the three were.

  Stamped from the scope rather than cast from attrs, because an issue is
  raised *by* a working copy — a report that could name someone else's would
  be worse than one that names none.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Issues

  defp attrs(overrides \\ %{}) do
    Map.merge(
      %{title: "something is wrong", severity: :low, description: "it is", scope: :framework},
      overrides
    )
  end

  test "an issue raised from a working copy records which one" do
    scope = full_scope_fixture()

    assert {:ok, issue} = Issues.create_issue(scope, attrs())
    assert issue.harness_id == scope.active_harness_id
    refute is_nil(issue.harness_id)
  end

  test "two checkouts of one project file distinguishable issues" do
    a = full_scope_fixture()
    {:ok, other} = CodeMySpec.Harnesses.issue(a, nil, label: "a second checkout")
    b = %{a | active_harness_id: other.id}

    {:ok, from_a} = Issues.create_issue(a, attrs(%{title: "raised from A"}))
    {:ok, from_b} = Issues.create_issue(b, attrs(%{title: "raised from B"}))

    refute from_a.harness_id == from_b.harness_id,
           "this is the question that gets asked about every report, and it " <>
             "should be answerable from the record rather than from the body text"
  end

  test "a scope with no working copy files an unattributed issue rather than failing" do
    scope = %{full_scope_fixture() | active_harness_id: nil}

    assert {:ok, issue} = Issues.create_issue(scope, attrs())

    assert is_nil(issue.harness_id),
           "the web UI has no checkout, and that is a legitimate nil rather than a gap"
  end

  test "the caller cannot name a working copy that is not its own" do
    scope = full_scope_fixture()
    {:ok, other} = CodeMySpec.Harnesses.issue(scope, nil, label: "somebody else")

    {:ok, issue} = Issues.create_issue(scope, attrs(%{harness_id: other.id}))

    assert issue.harness_id == scope.active_harness_id,
           "attribution comes from the scope; a report that could claim another " <>
             "checkout's identity would be worse than one with none"
  end
end
