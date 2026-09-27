defmodule CmsHarness.AServedProjectCanDecryptItsEnvFilesTest do
  use ExUnit.Case, async: true

  alias CmsHarness.SopsKeyring

  @moduletag :tmp_dir

  @dev "AGE-SECRET-KEY-1FAKEDEV"
  @test "AGE-SECRET-KEY-1FAKETEST"

  test "a key the keyring lacks is added, and one it holds is not added twice", %{tmp_dir: dir} do
    path = Path.join([dir, "sops", "age", "keys.txt"])

    assert {:ok, 2} = SopsKeyring.install([@dev, @test], path)
    assert {:ok, 0} = SopsKeyring.install([@dev, @test], path)

    assert File.read!(path) == @dev <> "\n" <> @test <> "\n"
    assert %{mode: mode} = File.stat!(path)

    assert Bitwise.band(mode, 0o077) == 0,
           "a keyring others can read leaks every project's secrets"
  end

  test "a hand-edited keyring keeps its own keys and gets ours on a line of their own",
       %{tmp_dir: dir} do
    path = Path.join(dir, "keys.txt")
    File.write!(path, "# created: by hand\nAGE-SECRET-KEY-1MINE")

    assert {:ok, 1} = SopsKeyring.install([@dev], path)

    assert File.read!(path) == "# created: by hand\nAGE-SECRET-KEY-1MINE\n" <> @dev <> "\n"
  end

  test "something that is not an age key is not written", %{tmp_dir: dir} do
    path = Path.join(dir, "keys.txt")

    assert {:ok, 0} = SopsKeyring.install(["", "not-a-key"], path)
    refute File.exists?(path)
  end
end
