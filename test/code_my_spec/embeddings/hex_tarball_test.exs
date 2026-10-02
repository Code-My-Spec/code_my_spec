defmodule CodeMySpec.Embeddings.HexTarballTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Embeddings.HexTarball
  alias CodeMySpecTest.HexTarballFixtures

  describe "ex_sources/1" do
    test "returns .ex files under lib/, keyed by path" do
      tarball =
        HexTarballFixtures.build(%{
          "lib/foo.ex" => "defmodule Foo do\nend\n",
          "lib/foo/bar.ex" => "defmodule Foo.Bar do\nend\n"
        })

      assert {:ok, sources} = HexTarball.ex_sources(tarball)

      assert sources == %{
               "lib/foo.ex" => "defmodule Foo do\nend\n",
               "lib/foo/bar.ex" => "defmodule Foo.Bar do\nend\n"
             }
    end

    test "a package with no lib/ sources at all returns an empty map, not an error" do
      tarball = HexTarballFixtures.build(%{})

      assert {:ok, %{}} = HexTarball.ex_sources(tarball)
    end

    test "non-.ex and non-lib/ entries are excluded" do
      tarball =
        HexTarballFixtures.build(%{
          "lib/kept.ex" => "defmodule Kept do\nend\n",
          "test/dropped_test.exs" => "defmodule DroppedTest do\nend\n",
          "src/dropped.erl" => "-module(dropped).\n",
          "README.md" => "# dropped\n"
        })

      assert {:ok, %{"lib/kept.ex" => _}} = HexTarball.ex_sources(tarball)
    end

    test "garbage bytes fail with a reason, not a crash" do
      assert {:error, {:outer_tar, _reason}} = HexTarball.ex_sources("not a tarball at all")
    end
  end
end
