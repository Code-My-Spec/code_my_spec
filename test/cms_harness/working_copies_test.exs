defmodule CmsHarness.WorkingCopiesTest do
  @moduledoc """
  Resolving a harness id to a directory from a file this project owns.

  The property is that a hook can be answered without the agent telling us
  where it is. What replaced the agent's answer has to survive the states a
  file has that an environment variable does not — absent, corrupt, rewritten
  — so those are what is covered here.
  """

  # Not async: the override is an environment variable, which is global to the
  # VM, so a concurrent test would read another's registry.
  use ExUnit.Case, async: false

  alias CmsHarness.WorkingCopies

  setup do
    {:ok, dir} = Briefly.create(directory: true)
    file = Path.join(dir, "harnesses.json")

    original = System.get_env("CMS_HARNESS_REGISTRY")
    System.put_env("CMS_HARNESS_REGISTRY", file)

    on_exit(fn -> restore(original) end)

    %{registry_file: file}
  end

  defp restore(nil), do: System.delete_env("CMS_HARNESS_REGISTRY")
  defp restore(value), do: System.put_env("CMS_HARNESS_REGISTRY", value)

  describe "a machine that has onboarded nothing" do
    test "knows nothing, rather than failing" do
      assert WorkingCopies.all() == %{}
      assert WorkingCopies.root(Ecto.UUID.generate()) == :unknown
    end
  end

  describe "after onboarding" do
    test "an id resolves to its directory", %{registry_file: file} do
      id = Ecto.UUID.generate()

      assert :ok = WorkingCopies.put(id, "/repo/main")
      assert File.exists?(file)
      assert WorkingCopies.root(id) == {:ok, "/repo/main"}
    end

    test "two checkouts of one project are two entries" do
      a = Ecto.UUID.generate()
      b = Ecto.UUID.generate()

      :ok = WorkingCopies.put(a, "/repo/main")
      :ok = WorkingCopies.put(b, "/repo/feature-x")

      assert WorkingCopies.root(a) == {:ok, "/repo/main"}
      assert WorkingCopies.root(b) == {:ok, "/repo/feature-x"}
    end

    test "a checkout that moves keeps its identity" do
      id = Ecto.UUID.generate()

      :ok = WorkingCopies.put(id, "/repo/old")
      :ok = WorkingCopies.put(id, "/repo/new")

      assert WorkingCopies.root(id) == {:ok, "/repo/new"},
             "the id being independent of the path is what buys this — the rows " <>
               "written under it stay attached across the move"
    end

    test "an unknown id stays unknown rather than resolving to a neighbour" do
      :ok = WorkingCopies.put(Ecto.UUID.generate(), "/repo/main")

      assert WorkingCopies.root(Ecto.UUID.generate()) == :unknown,
             "the behaviour this replaces walked up from the request's directory " <>
               "until it found a mix.exs, so an unonboarded checkout silently " <>
               "adopted whichever project was above it"
    end

    test "an entry can be withdrawn" do
      id = Ecto.UUID.generate()
      :ok = WorkingCopies.put(id, "/repo/main")

      assert :ok = WorkingCopies.delete(id)
      assert WorkingCopies.root(id) == :unknown
    end
  end

  describe "a file that cannot be trusted" do
    test "corrupt contents read as empty and are left on disk", %{registry_file: file} do
      File.write!(file, "{not json at all")

      assert WorkingCopies.all() == %{}

      assert File.read!(file) == "{not json at all",
             "whatever was in there is somebody's onboarding record; refusing to " <>
               "resolve is recoverable, rewriting it is not"
    end

    test "a JSON value that is not an object reads as empty", %{registry_file: file} do
      File.write!(file, ~s(["not", "an", "object"]))

      assert WorkingCopies.all() == %{}
    end
  end
end
