defmodule CodeMySpec.BootVersionLoadedSourcesTest do
  @moduledoc """
  What a landing has to change for the harness to be running stale code is
  read off the modules it has loaded, not a path list: the list missed
  `analysis/run_node.ex`, which the harness runs, and a fix stayed inert
  (issue 075d47f0).
  """
  use ExUnit.Case, async: false

  alias CodeMySpec.Analysis.RunNode
  alias CodeMySpec.BootVersion

  @key {BootVersion, :boot}

  setup do
    previous = :persistent_term.get(@key, nil)
    on_exit(fn -> restore(previous) end)
    :ok
  end

  defp restore(nil), do: :persistent_term.erase(@key)
  defp restore(previous), do: :persistent_term.put(@key, previous)

  test "names a loaded module outside any hand-kept list, relative to the checkout" do
    :persistent_term.put(@key, {File.cwd!(), nil})
    Code.ensure_loaded!(RunNode)

    sources = BootVersion.loaded_sources()

    assert "lib/code_my_spec/analysis/run_node.ex" in sources
    assert "lib/code_my_spec/boot_version.ex" in sources
    refute Enum.any?(sources, &String.starts_with?(&1, "/"))
  end

  test "is empty when the boot checkout is unknown" do
    :persistent_term.erase(@key)
    assert BootVersion.loaded_sources() == []
  end
end
