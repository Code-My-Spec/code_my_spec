defmodule CodeMySpec.ProviderModulesCompleteTest do
  @moduledoc """
  Every module that reads a `:plug` from its own app env must be in
  `CodeMySpecSpex.Case.provider_modules/0`.

  A module that reads a plug is asking to be recorded. Left out of the list it
  is never handed one, so its request escapes every cassette: on replay it goes
  to the real network, and while recording it raises `cannot find mock/stub`
  because `config/test.exs` pins the client to `Req.Test`.

  This has now happened four times — `Content.TriggerClient`,
  `Provisioning.Widget`, `Provisioning.ContentPublishing`, and
  `Provisioning.Deploy` — and each time the comment above the list was updated
  to say it must not happen again. The fourth cost a 470s recording of the full
  uat-and-prod sequence, which died in the deploy step after both servers had
  been built.

  The failure is invisible until someone records, and it names a stub rather
  than the omission, so nobody finds it by reading the list. A comment cannot
  enforce this; the list is data and the modules are data, so compare them.
  """
  use ExUnit.Case, async: true

  @plug_reader ~r/Application\.get_env\(:code_my_spec,\s*__MODULE__,\s*\[\]\)\[:plug\]/

  # Modules that read a plug but deliberately stay out of the list belong here,
  # each with the reason. Empty today: every plug reader is recorded.
  @deliberately_absent []

  test "every module reading a :plug is recorded by a cassette" do
    listed = MapSet.new(CodeMySpecSpex.Case.provider_modules())
    excused = MapSet.new(@deliberately_absent)

    readers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(&1 |> File.read!() |> then(fn s -> Regex.match?(@plug_reader, s) end)))
      |> Enum.map(&module_of/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    missing = readers |> MapSet.difference(listed) |> MapSet.difference(excused)

    assert MapSet.size(missing) == 0, """
    These modules read a `:plug` from their own app env but are not in
    `CodeMySpecSpex.Case.provider_modules/0`:

      #{missing |> Enum.map(&inspect/1) |> Enum.sort() |> Enum.join("\n  ")}

    So nothing hands them one. Their requests escape every cassette: on replay
    they reach the real network, and while recording they raise `cannot find
    mock/stub`, naming the client rather than this omission.

    Add them to that list, or to `@deliberately_absent` here with the reason.
    """
  end

  # The module a file defines, from its first `defmodule`. Good enough: these
  # are single-module provider files, and a file that defines none is skipped.
  defp module_of(path) do
    ~r/^defmodule\s+([A-Za-z0-9_.]+)\s+do/m
    |> Regex.run(File.read!(path), capture: :all_but_first)
    |> to_module()
  end

  defp to_module([name]), do: Module.concat([name])
  defp to_module(_), do: nil
end
