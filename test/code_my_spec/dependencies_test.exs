defmodule CodeMySpec.DependenciesTest do
  @moduledoc """
  The claim: hexdoc projection is driven by recorded state, not by winning a
  race against `mix deps.get`.

  What that buys is an observable end state — `pending/1` returning `[]` — where
  before there was only a ten-second timer and the hope that unpacking had
  finished. These test the properties that end state depends on.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Dependencies
  alias CodeMySpec.Dependencies.Lockfile

  setup do
    %{scope: full_scope_fixture()}
  end

  defp lock(entries) do
    body =
      Enum.map_join(entries, ",\n", fn
        {name, version} ->
          ~s(  "#{name}": {:hex, :#{name}, "#{version}", "chk", [:mix], [], "hexpm", "chk2"})

        {name, :git, sha} ->
          ~s(  "#{name}": {:git, "https://example.com/#{name}.git", "#{sha}", [branch: "main"]})
      end)

    "%{\n" <> body <> "\n}\n"
  end

  describe "parsing a lock" do
    test "reads hex packages at their pinned version" do
      assert {:ok, [%{name: "bandit", version: "1.10.4", source: "hex"}]} =
               Lockfile.parse(lock([{"bandit", "1.10.4"}]))
    end

    # A branch ref moves, so the sha is the only thing that actually pins a git
    # dependency — and therefore the only sane thing to treat as its version.
    test "pins a git package to its sha, not its branch" do
      assert {:ok, [%{name: "spex", version: "abc123", source: "git"}]} =
               Lockfile.parse(lock([{"spex", :git, "abc123"}]))
    end

    test "an unparseable lock is an error, not an empty dependency set" do
      assert {:error, :unparseable} = Lockfile.parse("%{ this is not")
    end

    # Distinct from the above: this one parsed, and it says there are no
    # dependencies. That is a fact about the project, not a failure to read it.
    test "an empty lock parses to an empty set" do
      assert {:ok, []} = Lockfile.parse("%{}\n")
    end
  end

  describe "recording a lock" do
    test "records every package", %{scope: scope} do
      assert {:ok, %{recorded: 2}} =
               Dependencies.record_lockfile(
                 scope,
                 lock([{"bandit", "1.10.4"}, {"plug", "1.18.0"}])
               )

      assert ["bandit", "plug"] = scope |> Dependencies.list_dependencies() |> Enum.map(& &1.name)
    end

    test "a package dropped from the lock is removed", %{scope: scope} do
      {:ok, _} =
        Dependencies.record_lockfile(scope, lock([{"bandit", "1.0.0"}, {"plug", "1.0.0"}]))

      {:ok, %{removed: 1}} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.0.0"}]))

      assert ["bandit"] = scope |> Dependencies.list_dependencies() |> Enum.map(& &1.name)
    end

    test "an unparseable lock changes nothing", %{scope: scope} do
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.0.0"}]))

      assert {:error, :unparseable} = Dependencies.record_lockfile(scope, "%{ broken")

      assert length(Dependencies.list_dependencies(scope)) == 1,
             "a lock that could not be read must not be able to say a project has no dependencies"
    end
  end

  describe "convergence" do
    test "a newly recorded package is pending", %{scope: scope} do
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.10.4"}]))

      assert ["bandit"] = scope |> Dependencies.pending() |> Enum.map(& &1.name)
    end

    test "projecting a package settles it", %{scope: scope} do
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.10.4"}]))
      :ok = Dependencies.mark_projected(scope, "bandit", "1.10.4")

      assert Dependencies.pending(scope) == [],
             "an empty pending set is the end state the settle timer never had"
    end

    # The property that makes this safe to call on every lock event: re-recording
    # an unchanged lock must not undo projection work.
    test "re-recording an unchanged lock leaves nothing pending", %{scope: scope} do
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.10.4"}]))
      :ok = Dependencies.mark_projected(scope, "bandit", "1.10.4")

      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.10.4"}]))

      assert Dependencies.pending(scope) == []
    end

    test "a bumped package becomes pending again", %{scope: scope} do
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.10.4"}]))
      :ok = Dependencies.mark_projected(scope, "bandit", "1.10.4")

      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.11.0"}]))

      assert ["bandit"] = scope |> Dependencies.pending() |> Enum.map(& &1.name)
    end

    # The race this design replaces, in miniature: a package re-pinned while its
    # docs were being projected must not be marked current for a version nobody
    # projected.
    test "marking a version that is no longer pinned settles nothing", %{scope: scope} do
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.10.4"}]))
      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.11.0"}]))

      :ok = Dependencies.mark_projected(scope, "bandit", "1.10.4")

      assert ["bandit"] = scope |> Dependencies.pending() |> Enum.map(& &1.name)
    end
  end

  describe "scoping" do
    test "one project's dependencies are not another's", %{scope: scope} do
      other = full_scope_fixture()

      {:ok, _} = Dependencies.record_lockfile(scope, lock([{"bandit", "1.0.0"}]))
      {:ok, _} = Dependencies.record_lockfile(other, lock([{"plug", "1.0.0"}]))

      assert ["bandit"] = scope |> Dependencies.list_dependencies() |> Enum.map(& &1.name)
      assert ["plug"] = other |> Dependencies.list_dependencies() |> Enum.map(& &1.name)
    end
  end
end
