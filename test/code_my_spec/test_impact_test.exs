defmodule CodeMySpec.TestImpactTest do
  use ExUnit.Case, async: true

  require Mix.Compilers.Elixir, as: CE

  alias CodeMySpec.TestImpact

  # A chain a <- b <- c (runtime, then export), a macro user e of m, an
  # independent d, and r with an external resource.
  #
  #   lib/a.ex  A
  #   lib/b.ex  B  -> A (runtime)
  #   lib/c.ex  C  -> B (export)
  #   lib/d.ex  D
  #   lib/m.ex  M
  #   lib/e.ex  E  -> M (compile)
  #   lib/r.ex  R  external priv/data.txt
  defp source(modules, opts \\ []) do
    CE.source(
      modules: modules,
      runtime_references: Keyword.get(opts, :runtime, []),
      compile_references: Keyword.get(opts, :compile, []),
      export_references: Keyword.get(opts, :export, []),
      external: Keyword.get(opts, :external, [])
    )
  end

  defp baseline do
    sources = %{
      "lib/a.ex" => source([A]),
      "lib/b.ex" => source([B], runtime: [A]),
      "lib/c.ex" => source([C], export: [B]),
      "lib/d.ex" => source([D]),
      "lib/m.ex" => source([M]),
      "lib/e.ex" => source([E], compile: [M]),
      # The compile manifest records `{path, mtime_and_size, digest}`.
      "lib/r.ex" => source([R], external: [{"priv/data.txt", {1, 1}, <<0>>}])
    }

    modules =
      for {path, CE.source(modules: [module])} <- sources,
          into: %{},
          do: {module, CE.module(kind: :module, sources: [path])}

    # `Mix.Compilers.Test`'s `source` record: compile, runtime, external.
    test_sources = %{
      "test/a_test.exs" => {:source, [], [A], []},
      "test/b_test.exs" => {:source, [], [B], []},
      "test/c_test.exs" => {:source, [], [C], []},
      "test/d_test.exs" => {:source, [], [D], []},
      "test/e_test.exs" => {:source, [E], [], []},
      "test/r_test.exs" => {:source, [], [R], []},
      "test/fixture_test.exs" => {:source, [], [], ["test/fixtures/x.json"]}
    }

    %{
      modules: modules,
      sources: sources,
      test_sources: test_sources,
      tests: Map.keys(test_sources)
    }
  end

  defp select(changed, opts \\ []),
    do: baseline() |> Map.put(:changed, changed) |> TestImpact.select(opts)

  describe "a changed lib file" do
    test "selects its tests and the tests of everything that depends on it, transitively" do
      result = select(["lib/a.ex"])

      assert result.mode == :partial
      assert result.tests == ["test/a_test.exs", "test/b_test.exs", "test/c_test.exs"]
      assert result.reasons["test/c_test.exs"] == {:references, C}
      assert result.seeds == [A]
    end

    test "leaves independent tests out" do
      assert select(["lib/d.ex"]).tests == ["test/d_test.exs"]
    end

    test "follows compile-time references" do
      assert select(["lib/m.ex"]).tests == ["test/e_test.exs"]
    end

    test "a module whose file was deleted still seeds from the baseline" do
      baseline = baseline()

      deleted =
        baseline
        |> Map.put(:tests, List.delete(baseline.tests, "test/d_test.exs"))
        |> Map.put(:changed, ["lib/d.ex", "test/d_test.exs"])
        |> TestImpact.select()

      assert deleted.mode == :partial
      assert deleted.tests == []
      assert deleted.seeds == [D]
    end
  end

  describe "external resources" do
    test "a changed resource a lib source declares seeds that source's modules" do
      result = select(["priv/data.txt"])

      assert result.tests == ["test/r_test.exs"]
      assert result.unclassified == []
    end

    test "a changed resource a test declares selects that test" do
      result = select(["test/fixtures/x.json"])

      assert result.tests == ["test/fixture_test.exs"]
      assert result.reasons["test/fixture_test.exs"] == :external
    end
  end

  describe "test files" do
    test "a changed test file is selected" do
      result = select(["test/d_test.exs"])

      assert result.tests == ["test/d_test.exs"]
      assert result.reasons["test/d_test.exs"] == :changed
    end

    test "a test file the baseline never saw is selected" do
      result =
        baseline()
        |> Map.update!(:tests, &["test/new_test.exs" | &1])
        |> Map.put(:changed, ["test/new_test.exs"])
        |> TestImpact.select()

      assert result.tests == ["test/new_test.exs"]
      assert result.reasons["test/new_test.exs"] == :new
    end
  end

  test "an untracked unrelated test is not selected" do
    result =
      baseline()
      |> Map.update!(:tests, &["test/unrelated_test.exs" | &1])
      |> Map.put(:changed, ["lib/d.ex"])
      |> TestImpact.select()

    assert result.tests == ["test/d_test.exs"]
  end

  test "test_helper alone does not force a whole-suite selection" do
    assert select(["test/test_helper.exs"]).mode == :partial
  end

  describe "whole-suite fallbacks" do
    test "a default force-full path runs every test" do
      for path <- ["config/config.exs", "config/runtime.exs", "mix.exs", "mix.lock"] do
        result = select([path])
        assert result.mode == :all, path
        assert result.why_all =~ path
        assert length(result.tests) == 7
      end
    end

    test "force-full globs can be replaced" do
      assert select(["config/runtime.exs"], force_full: ["rel/**"]).mode == :partial
      assert select(["rel/overlays/x"], force_full: ["rel/**"]).mode == :all
    end

    test "an unclassified file is reported, and refused when strict" do
      assert %{mode: :partial, tests: [], unclassified: ["README.md"]} = select(["README.md"])

      strict = select(["README.md"], strict: true)
      assert strict.mode == :all
      assert strict.why_all =~ "README.md"
    end

    test "no usable baseline manifests runs every test" do
      result =
        %{modules: %{}, sources: %{}, test_sources: %{}, tests: ["test/a_test.exs"], changed: []}
        |> TestImpact.select()

      assert result.mode == :all
      assert result.why_all =~ "no usable baseline"
    end
  end

  describe "reference_map_script/0" do
    # Run as `mix run -e` in a project's own VM, where a syntax error would
    # only show as a gate that never records a selection.
    test "is a well-formed script that writes compile.test_refs" do
      script = TestImpact.reference_map_script()

      assert {:ok, _} = Code.string_to_quoted(script)
      assert script =~ "compile.test_refs"
    end
  end

  describe "read_baseline/1" do
    @tag :tmp_dir
    test "an absent or unrecognised manifest is an error, never an empty baseline", %{
      tmp_dir: dir
    } do
      assert {:error, why} = TestImpact.read_baseline(dir)
      assert why =~ "compile.elixir"

      File.write!(Path.join(dir, "compile.elixir"), "not a manifest")
      assert {:error, _} = TestImpact.read_baseline(dir)
    end
  end
end
