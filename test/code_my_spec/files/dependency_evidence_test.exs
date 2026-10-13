defmodule CodeMySpec.Files.DependencyEvidenceTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Files.DependencyEvidence

  test "resolves qualified calls, aliases, grouped aliases, captures, and structs" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Worker do
        alias App.Services, as: Services
        alias App.{Repo, Types}
        def run(x) do
          Services.save(x)
          Repo.fetch(x)
          &Types.parse/1
          %App.Record{id: x}
          Elixir.App.Clock.now()
        end
      end
      """)

    assert result["status"] == "ok"
    assert result["modules"] == ["App.Worker"]

    assert Enum.map(result["references"], &{&1["target"], &1["kind"]}) == [
             {"App.Clock", "call"},
             {"App.Record", "struct"},
             {"App.Repo", "call"},
             {"App.Services", "call"},
             {"App.Types", "call"}
           ]
  end

  test "unused aliases, config keys, specs, and quoted code do not create edges" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Config do
        alias App.Unused
        @spec call(App.Type.t()) :: App.Result.t()
        @doc "mentions App.Doc"
        def settings, do: %{Repo: :module, adapter: App.Adapter}
        def quoted, do: quote(do: App.Quoted.run())
      end
      """)

    assert result["references"] == []
  end

  test "nested module and function aliases stay in their lexical scopes" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Root do
        def first do
          alias App.One
          One.call()
        end
        def second, do: One.call()
        defmodule Child do
          alias App.Two
          Two.call()
        end
        def after_child, do: Two.call()
      end
      """)

    refs = result["references"]
    assert Enum.any?(refs, &(&1["source"] == "App.Root" and &1["target"] == "App.One"))
    assert Enum.any?(refs, &(&1["source"] == "App.Root.Child" and &1["target"] == "App.Two"))
    assert Enum.any?(refs, &(&1["source"] == "App.Root" and &1["target"] == "One"))
    assert Enum.any?(refs, &(&1["source"] == "App.Root" and &1["target"] == "Two"))
  end

  test "dynamic module calls and unresolved apply are reported without invented edges" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Runner do
        def run(mod), do: (mod).go()
        def apply_dynamic(mod), do: apply(mod, :go, [])
      end
      """)

    assert result["references"] == []

    assert Enum.map(result["unresolved"], & &1["reason"]) |> Enum.sort() ==
             ["dynamic_apply", "dynamic_module_call"]
  end

  test "field access on a value is not a module call" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Runner do
        alias App.Accounts
        def run(copy, state), do: Accounts.fetch(copy.root, state.copy.id)
      end
      """)

    assert [%{"target" => "App.Accounts"}] = result["references"]
    assert result["unresolved"] == []
  end

  test "an import is the reference, its calls add no uncertainty, and Boundary config stays data" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Policy do
        import App.Helpers
        use Boundary, deps: [App.Accounts, App.Billing]
        def run, do: imported_helper()
      end
      """)

    assert Enum.map(result["references"], &{&1["target"], &1["kind"]}) ==
             [{"App.Helpers", "macro"}, {"Boundary", "macro"}]

    assert result["unresolved"] == []

    refute Enum.any?(result["references"], &(&1["target"] in ["App.Accounts", "App.Billing"]))
  end

  test "alias as expansion and nested __MODULE__ modules resolve exactly" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Outer do
        alias App.Services.Repository, as: Renamed
        defmodule __MODULE__.Child do
          Renamed.fetch()
          __MODULE__.Sibling.run()
        end
      end
      """)

    assert result["modules"] == ["App.Outer", "App.Outer.Child"]

    assert Enum.map(result["references"], &{&1["source"], &1["target"]}) == [
             {"App.Outer.Child", "App.Outer.Child.Sibling"},
             {"App.Outer.Child", "App.Services.Repository"}
           ]
  end

  test "structs and remote calls in function heads are recorded" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Matcher do
        alias App.Record, as: Record
        def match(%Record{} = record) when App.Guards.valid?(record), do: App.Result.ok()
      end
      """)

    assert Enum.map(result["references"], &{&1["target"], &1["kind"]}) == [
             {"App.Guards", "call"},
             {"App.Record", "struct"},
             {"App.Result", "call"}
           ]
  end

  test "quoted modules are excluded and branch aliases do not leak" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Scopes do
        quote do
          defmodule App.Quoted do
          end
        end
        if enabled do
          alias App.Branch
          Branch.run()
        end
        App.After.run()
      end
      """)

    assert result["modules"] == ["App.Scopes"]
    assert Enum.map(result["references"], & &1["target"]) == ["App.After", "App.Branch"]
  end

  test "function rescue bodies and all do-branch clauses are walked in isolation" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Rescue do
        def run do
          App.Work.start()
        rescue
          error -> App.Errors.handle(error)
        catch
          kind, value -> App.Catches.handle(kind, value)
        after
          App.Cleanup.finish()
        end

        def branches(value) do
          case value do
            :one ->
              alias App.First
              First.run()
            :two -> App.Second.run()
          end
          if value do
            alias App.OnlyInDo
            OnlyInDo.run()
          else
            App.Else.run()
          end
          App.After.run()
        end
      end
      """)

    targets = Enum.map(result["references"], & &1["target"])

    assert targets == [
             "App.After",
             "App.Catches",
             "App.Cleanup",
             "App.Else",
             "App.Errors",
             "App.First",
             "App.OnlyInDo",
             "App.Second",
             "App.Work"
           ]
  end

  test "a declared child module becomes available as an outer lexical alias" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Parent do
        defmodule Child do
          def run, do: :ok
        end
        Child.run()
      end
      """)

    assert result["modules"] == ["App.Parent", "App.Parent.Child"]

    assert result["references"] == [
             %{
               "source" => "App.Parent",
               "target" => "App.Parent.Child",
               "kind" => "call",
               "line" => 5
             }
           ]
  end

  test "dynamic module definitions are unresolved without crashing or inventing edges" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Dynamic do
        defmodule module_name do
          App.Unknown.call()
        end
      end
      """)

    assert result["modules"] == ["App.Dynamic"]
    assert result["references"] == []

    assert result["unresolved"] == [
             %{
               "source" => "App.Dynamic",
               "line" => 2,
               "reason" => "dynamic_module_definition"
             }
           ]
  end

  test "unusual parser error terms are serialized instead of raising" do
    result = DependencyEvidence.extract("defmodule Broken do\n")
    assert result["status"] == "error"
    assert is_binary(result["parse_error"]["message"])
  end

  test "macro declarations, static apply, and malformed input have explicit evidence" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Consumer do
        use App.Framework
        def run, do: apply(App.Service, :work, [])
      end
      """)

    assert Enum.map(result["references"], &{&1["target"], &1["kind"]}) ==
             [{"App.Framework", "macro"}, {"App.Service", "call"}]

    error = DependencyEvidence.extract("defmodule Broken do\n")
    assert error["status"] == "error"
    assert is_map(error["parse_error"])

    assert error["source_hash"] ==
             :crypto.hash(:sha256, "defmodule Broken do\n") |> Base.encode16(case: :lower)
  end

  test "a use Boundary declaration is recorded with its options, per module" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Accounts do
        use Boundary, top_level?: true, deps: [App.Repo], exports: :all
        defmodule Tasks do
          use Boundary, classify_to: App
        end
      end
      defmodule App.Plain do
        use GenServer
      end
      """)

    assert result["boundaries"] == [
             %{"module" => "App.Accounts", "top_level" => true, "classify_to" => nil},
             %{"module" => "App.Accounts.Tasks", "top_level" => false, "classify_to" => "App"}
           ]
  end

  test "interpolation and Erlang calls are static, not dynamic" do
    result =
      DependencyEvidence.extract("""
      defmodule App.Label do
        def label(env), do: "env/\#{env}"
        def lookup(key), do: :ets.lookup(:t, key)
      end
      """)

    assert result["unresolved"] == []
    assert {"Kernel", "call"} in Enum.map(result["references"], &{&1["target"], &1["kind"]})
    assert {":ets", "call"} in Enum.map(result["references"], &{&1["target"], &1["kind"]})
  end
end
