defmodule CodeMySpec.EpicDispatchFetchTest do
  @moduledoc """
  An id that is not an id is "no such epic", not a stack trace.

  `Repo.get_by/3` raises on a value it cannot dump to `:binary_id` rather than
  answering nil, and the raise reaches an agent as the Ecto query printed out.
  Found by calling `propose_epic` with `"999999"` while checking that the tool
  was reachable at all:

      propose_epic crashed: value `"999999"` cannot be dumped to type :binary_id
      in query: from e0 in CodeMySpec.Epics.Epic, where: ...

  That reads as a broken tool. An agent that gets it has no reason to think it
  passed a bad argument, and the codebase spends real care elsewhere making
  refusals say what to do instead.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.EpicDispatch

  setup do
    %{scope: full_scope_fixture()}
  end

  test "a malformed id is refused rather than raised", %{scope: scope} do
    assert {:error, :not_found} = EpicDispatch.propose(scope, "999999")
  end

  test "a well-formed id for no epic is the same answer", %{scope: scope} do
    assert {:error, :not_found} =
             EpicDispatch.propose(scope, "00000000-0000-4000-8000-000000000000"),
           "two answers here would only invite an agent to try spelling the id " <>
             "differently. There is no epic either way."
  end

  test "nil does not raise either", %{scope: scope} do
    assert {:error, :not_found} = EpicDispatch.propose(scope, nil)
  end
end
