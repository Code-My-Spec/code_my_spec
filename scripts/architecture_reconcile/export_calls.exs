# Read Boundary's existing compiler trace; never treat alias references as calls.
defmodule ArchitectureCalls do
  def extract(rows) do
    Enum.filter(rows, fn {source, ref} ->
      source != ref.to and ref.type in [:call, :struct_expansion]
    end)
  end

  def export do
    manifest = "_build/dev/lib/code_my_spec/.mix/compile.boundary_references"
    {:ok, table} = :ets.file2tab(String.to_charlist(manifest))
    rows = :ets.tab2list(table)

    modules =
      Path.wildcard("_build/dev/lib/code_my_spec/ebin/*.beam")
      |> Enum.flat_map(fn beam ->
        {:ok, {module, chunks}} = :beam_lib.chunks(String.to_charlist(beam), [:compile_info])
        source = chunks[:compile_info][:source] |> to_string() |> Path.relative_to(File.cwd!())

        if String.starts_with?(source, "lib/") and File.regular?(source),
          do: [%{name: inspect(module), path: source}],
          else: []
      end)

    evidence = fn entries ->
      Enum.map(entries, fn {source, ref} ->
        %{
          source: inspect(source),
          target: inspect(ref.to),
          kind: ref.type,
          file: ref.file,
          line: ref.line,
          mode: ref.mode,
          function: inspect(ref.from_function)
        }
      end)
    end

    %{
      modules: modules,
      evidence: evidence.(extract(rows)),
      references_only:
        evidence.(Enum.filter(rows, fn {_, ref} -> ref.type == :alias_reference end)),
      manifest_sha256: :crypto.hash(:sha256, File.read!(manifest)) |> Base.encode16(case: :lower)
    }
  end
end

unless System.get_env("ARCHITECTURE_EXTRACT_TEST") do
  [output] = System.argv()
  File.write!(output, Jason.encode!(ArchitectureCalls.export(), pretty: true), [:exclusive])
end
