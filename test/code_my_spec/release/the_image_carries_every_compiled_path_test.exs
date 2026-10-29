defmodule CodeMySpec.Release.TheImageCarriesEveryCompiledPathTest do
  @moduledoc """
  The production image compiles what the Dockerfile copies, and `mix.exs`
  says what :prod compiles. A path compiled but not copied builds cleanly and
  dies at boot on the missing module: v2.0.704 shipped without `lib_server`
  (OrtexServing) and crashed until rolled back.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)

  test "every :prod compile path is copied into the build" do
    copied =
      Regex.scan(~r/^COPY (\S+) \S+$/m, File.read!(Path.join(@root, "Dockerfile")))
      |> Enum.map(fn [_, source] -> source end)

    [_, listed] =
      Regex.run(
        ~r/defp elixirc_paths\(_\), do: \[([^\]]*)\]/,
        File.read!(Path.join(@root, "mix.exs"))
      )

    paths = Regex.scan(~r/"([^"]+)"/, listed) |> Enum.map(fn [_, path] -> path end)

    assert paths != []

    for path <- paths do
      assert path in copied, "Dockerfile does not copy #{path}, which :prod compiles"
    end
  end
end
