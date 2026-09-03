defmodule CodeMySpec.Requirements.GraphCacheScopingTest do
  @moduledoc """
  A cached graph belongs to the checkout it was computed from.

  `NodeRepository.upsert_all/2` has written and deleted per working copy since
  the fix its own comment describes — "writing it without saying so is what let
  any checkout overwrite the project's whole graph". The cache that *gates*
  those writes kept the project grain, so publishing from one checkout made
  another checkout's computation answer `:unchanged`, and
  `persist_projection/5` wrote nothing for it.

  What that looked like: stories 989/990/991 had their spec files, carrying
  story ids, in the devops-q checkout, and `bdd_specs_exist` still read
  unsatisfied. The only rows for those stories belonged to the main checkout —
  correctly false there, since the files were uncommitted — and devops-q had no
  requirement rows at all, out of 10,017 in the table. Found by devops-q-ec;
  issue `5b538c8b`.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.GraphCache
  alias CodeMySpec.WorkingCopies

  defp second_copy(scope) do
    {:ok, device} = CodeMySpec.Devices.announce(scope, nil, %{hostname: "box", kind: :local})
    {:ok, copy} = WorkingCopies.issue(scope, nil, label: "another checkout", device: device)
    copy
  end

  defp graph, do: {[], []}

  test "publishing from one checkout does not silence another" do
    scope = full_scope_fixture()
    other = second_copy(scope)
    elsewhere = %{scope | active_working_copy_id: other.id}

    assert GraphCache.publish(scope, "fingerprint-a", graph()) == :published

    assert GraphCache.publish(elsewhere, "fingerprint-b", graph()) == :published, """
    The second checkout was told nothing had changed, so `persist_projection/5`
    wrote no requirement rows for it — and it then read the first checkout's
    verdict about files it does not have.
    """
  end

  test "a checkout still short-circuits its own unchanged republish" do
    scope = full_scope_fixture()

    assert GraphCache.publish(scope, "fingerprint-a", graph()) == :published

    assert GraphCache.publish(scope, "fingerprint-a", graph()) == :unchanged,
           "the short-circuit is why this cache exists — the UI computes on every render"
  end

  test "two checkouts on the same inputs each keep a row" do
    scope = full_scope_fixture()
    other = second_copy(scope)
    elsewhere = %{scope | active_working_copy_id: other.id}

    # The same fingerprint from both, which is the case the project-keyed
    # conflict target collapsed into one row.
    assert GraphCache.publish(scope, "same-fingerprint", graph()) == :published
    assert GraphCache.publish(elsewhere, "same-fingerprint", graph()) == :published

    assert {:ok, _payload, _at} = GraphCache.fetch(scope, "same-fingerprint")
    assert {:ok, _payload2, _at2} = GraphCache.fetch(elsewhere, "same-fingerprint")
  end

  test "one checkout's cache is not served to another" do
    scope = full_scope_fixture()
    other = second_copy(scope)
    elsewhere = %{scope | active_working_copy_id: other.id}

    assert GraphCache.publish(scope, "fingerprint-a", graph()) == :published

    assert GraphCache.fetch(elsewhere, "fingerprint-a") == :miss, """
    A checkout was served a graph computed from a different checkout's files.
    That is the whole failure: the payload describes what one tree could see,
    and handing it to another reports files that are not there.
    """
  end

  test "the blended UI vantage keeps its own row rather than matching nothing" do
    scope = full_scope_fixture()
    ui = %{scope | active_working_copy_id: nil}

    assert GraphCache.publish(ui, "fingerprint-ui", graph()) == :published
    assert {:ok, _payload, _at} = GraphCache.fetch(ui, "fingerprint-ui")

    assert GraphCache.fetch(scope, "fingerprint-ui") == :miss,
           "a checkout was served the blended cross-checkout graph as though it were its own"
  end
end
