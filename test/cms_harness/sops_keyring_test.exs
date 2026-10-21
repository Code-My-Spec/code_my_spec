defmodule CmsHarness.SopsKeyringTest do
  use ExUnit.Case, async: true

  alias CmsHarness.SopsKeyring

  @dev "AGE-SECRET-KEY-1FAKEDEV"
  @test_key "AGE-SECRET-KEY-1FAKETEST"

  setup do
    {:ok, pid} = SopsKeyring.start_link(name: nil)
    {:ok, keyring: pid}
  end

  test "a key the keyring lacks is added, and one it holds is not added twice", %{keyring: kr} do
    assert {:ok, 2} = SopsKeyring.install([@dev, @test_key], kr)
    assert {:ok, 0} = SopsKeyring.install([@dev, @test_key], kr)

    assert Enum.sort(SopsKeyring.keys(kr)) == Enum.sort([@dev, @test_key])
    assert SopsKeyring.holding_key?(kr)
  end

  test "something that is not an age key is not held", %{keyring: kr} do
    assert {:ok, 0} = SopsKeyring.install(["", "not-a-key"], kr)
    assert SopsKeyring.keys(kr) == []
    refute SopsKeyring.holding_key?(kr)
  end

  test "an empty list is a no-op", %{keyring: kr} do
    assert {:ok, 0} = SopsKeyring.install([], kr)
    assert SopsKeyring.keys(kr) == []
  end
end
