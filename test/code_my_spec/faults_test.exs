defmodule CodeMySpec.FaultsTest do
  @moduledoc """
  The property the whole seam exists for: a fault reaches one key and no other.

  Issue `0fb7bf03`. The seams these replace were node-global, so "make the
  digest fail" and "take the box down for everyone" were the same action, and
  five QA passes in a row declined to take it. A test that only checked the
  fault fires would pass on the old `Application.put_env/3` too — what has to be
  asserted is the half that was missing: the neighbour is untouched.
  """

  use ExUnit.Case, async: false

  alias CodeMySpec.Faults

  setup do
    on_exit(fn -> Faults.clear_all() end)
    :ok
  end

  describe "scope" do
    test "reaches the key it was injected against and no other" do
      :ok = Faults.inject("project-a", :digest_unavailable)

      assert Faults.active?("project-a", :digest_unavailable)
      refute Faults.active?("project-b", :digest_unavailable)
    end

    test "a key is broken in one way without being broken in another" do
      :ok = Faults.inject("session-1", :intake_shaper_fails)

      assert Faults.active?("session-1", :intake_shaper_fails)
      refute Faults.active?("session-1", :digest_unavailable)
    end

    test "no key is not every key" do
      :ok = Faults.inject("project-a", :digest_unavailable)

      refute Faults.active?(nil, :digest_unavailable)
    end
  end

  describe "inject" do
    test "refuses a fault nothing checks for, naming the ones that exist" do
      assert {:error, {:unknown_fault, known}} = Faults.inject("project-a", :no_such_fault)

      assert :digest_unavailable in known
      refute Faults.active?("project-a", :no_such_fault)
    end
  end

  describe "clear" do
    test "puts one back and leaves the rest" do
      :ok = Faults.inject("project-a", :digest_unavailable)
      :ok = Faults.inject("project-b", :digest_unavailable)

      :ok = Faults.clear("project-a", :digest_unavailable)

      refute Faults.active?("project-a", :digest_unavailable)
      assert Faults.active?("project-b", :digest_unavailable)
    end

    test "clear_all says how much it removed" do
      :ok = Faults.inject("project-a", :digest_unavailable)
      :ok = Faults.inject("session-1", :intake_shaper_fails)

      assert Faults.clear_all() == 2
      assert Faults.list() == []
    end
  end

  describe "list" do
    test "shows what was left behind, so a caller can find its own mess" do
      :ok = Faults.inject("project-a", :digest_unavailable)

      assert Faults.list() == [%{key: "project-a", fault: :digest_unavailable}]
    end
  end
end
