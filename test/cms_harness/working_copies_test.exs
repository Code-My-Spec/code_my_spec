defmodule CmsHarness.WorkingCopiesTest do
  @moduledoc """
  Resolving a harness id to a directory without asking anyone.

  The property is that a hook can be answered from the harness's own
  configuration and the disk it is already watching — no database, no server
  round trip, nothing the agent supplied. That is what lets a sprite serve its
  first hook before it has finished connecting.
  """

  # Not async: the configured roots come from an environment variable and
  # application config, both global to the VM.
  use ExUnit.Case, async: false

  alias CmsHarness.WorkingCopies

  setup do
    original = System.get_env("CMS_PROJECT_DIR")
    on_exit(fn -> restore(original) end)

    :ok
  end

  defp restore(nil), do: System.delete_env("CMS_PROJECT_DIR")
  defp restore(value), do: System.put_env("CMS_PROJECT_DIR", value)

  defp checkout(id) do
    {:ok, root} = Briefly.create(directory: true)
    File.write!(Path.join(root, ".cms_harness_id"), id <> "\n")
    root
  end

  describe "a copy this harness was told to serve" do
    test "resolves by the id written in it" do
      id = Ecto.UUID.generate()
      root = checkout(id)
      System.put_env("CMS_PROJECT_DIR", root)

      assert WorkingCopies.root(id) == {:ok, root}
    end

    test "an id nobody wrote is unknown, not the nearest checkout" do
      root = checkout(Ecto.UUID.generate())
      System.put_env("CMS_PROJECT_DIR", root)

      assert WorkingCopies.root(Ecto.UUID.generate()) == :unknown,
             "the behaviour this replaces walked up from the request's directory " <>
               "until it found a mix.exs, so an unonboarded copy adopted whichever " <>
               "project sat above it"
    end

    test "appears in the set this harness knows about" do
      id = Ecto.UUID.generate()
      root = checkout(id)
      System.put_env("CMS_PROJECT_DIR", root)

      assert Map.get(WorkingCopies.all(), id) == root
    end
  end

  describe "a copy with no identity yet" do
    test "is not resolvable and does not crash the lookup" do
      {:ok, root} = Briefly.create(directory: true)
      System.put_env("CMS_PROJECT_DIR", root)

      assert WorkingCopies.root(Ecto.UUID.generate()) == :unknown
      refute Enum.any?(WorkingCopies.all(), fn {_id, r} -> r == root end)
    end
  end

  describe "a harness serving nothing" do
    test "knows nothing rather than failing" do
      System.delete_env("CMS_PROJECT_DIR")

      assert WorkingCopies.root(Ecto.UUID.generate()) == :unknown
    end

    test "an empty or malformed id never resolves" do
      for id <- ["", "   ", nil, 42] do
        assert WorkingCopies.root(id) == :unknown
      end
    end
  end
end
