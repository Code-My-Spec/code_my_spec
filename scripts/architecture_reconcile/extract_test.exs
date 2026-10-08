System.put_env("ARCHITECTURE_EXTRACT_TEST", "1")
Code.require_file("export_calls.exs", __DIR__)
ExUnit.start()

defmodule ArchitectureTraceFixture do
  def trace({kind, meta, target, _name, _arity}, env)
      when kind in [:remote_function, :remote_macro, :imported_function, :imported_macro] do
    record(env, meta, target, :call)
  end

  def trace({:struct_expansion, meta, target, _}, env),
    do: record(env, meta, target, :struct_expansion)

  def trace({:alias_reference, meta, target}, env),
    do: record(env, meta, target, :alias_reference)

  def trace(_, _), do: :ok

  defp record(env, meta, target, type) do
    :ets.insert(:architecture_test, {env.module, %{to: target, type: type, line: meta[:line]}})
    :ok
  end
end

defmodule ArchitectureCallsTest do
  use ExUnit.Case

  test "compiler evidence separates config atoms, calls, structs and secondary modules" do
    :ets.new(:architecture_test, [:named_table, :public, :bag])
    old = Code.get_compiler_option(:tracers)
    Code.put_compiler_option(:tracers, [ArchitectureTraceFixture])

    try do
      Code.compile_string("""
      defmodule ArchitectureFixture.Target do
        defstruct [:id]
        def run, do: :ok
        defmacro marker, do: quote(do: :ok)
      end
      defmodule ArchitectureFixture.Config do
        def key, do: Application.get_env(:example, ArchitectureFixture.Target)
      end
      defmodule ArchitectureFixture.Caller do
        def run, do: ArchitectureFixture.Target.run()
        def capture, do: &ArchitectureFixture.Target.run/0
      end
      defmodule ArchitectureFixture.StructUser do
        def build, do: %ArchitectureFixture.Target{}
      end
      defmodule ArchitectureFixture.MacroUser do
        require ArchitectureFixture.Target
        ArchitectureFixture.Target.marker()
      end
      """)

      rows = :ets.tab2list(:architecture_test)
      pairs = ArchitectureCalls.extract(rows) |> MapSet.new(fn {from, r} -> {from, r.to} end)
      refute MapSet.member?(pairs, {ArchitectureFixture.Config, ArchitectureFixture.Target})

      for source <- [
            ArchitectureFixture.Caller,
            ArchitectureFixture.StructUser,
            ArchitectureFixture.MacroUser
          ] do
        assert MapSet.member?(pairs, {source, ArchitectureFixture.Target})
      end

      assert Enum.any?(rows, fn {s, r} ->
               s == ArchitectureFixture.Config and r.to == ArchitectureFixture.Target and
                 r.type == :alias_reference
             end)
    after
      Code.put_compiler_option(:tracers, old)
      :ets.delete(:architecture_test)
    end
  end
end
