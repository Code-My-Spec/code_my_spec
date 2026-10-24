defmodule CmsHarness.SobelowOutputFidelityTest do
  use ExUnit.Case, async: false

  alias CmsHarness.Analysis
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.ExecutionContexts.Local
  alias CodeMySpec.StaticAnalysis.SobelowRun

  @output " \t\n{\"findings\":{\"high_confidence\":[{\"type\":\"SQL Injection\",\"file\":\"lib/example.ex\"}],\"medium_confidence\":[],\"low_confidence\":[]}}\n \t\n"

  @tag :tmp_dir
  test "captured whitespace survives the runner and serialized harness payload", %{tmp_dir: root} do
    File.write!(Path.join(root, "mix.exs"), "# fixture")
    File.mkdir_p!(Path.join(root, "deps/sobelow"))
    File.mkdir_p!(Path.join(root, ".claude"))

    File.write!(
      Path.join([root, ".claude", "settings.local.json"]),
      Jason.encode!(%{
        "env" => %{"MIX_TEST_PARTITION" => "fixture#{System.unique_integer([:positive])}"}
      })
    )

    :meck.new(Local, [:passthrough, :no_link])
    on_exit(fn -> :meck.unload(Local) end)

    :meck.expect(Local, :cmd, fn _env,
                                 "mix",
                                 ["sobelow", "--format", "json", "--private"],
                                 _opts ->
      {@output, 1}
    end)

    env = ExecutionContext.new(:local, root)
    assert {:ok, findings, output} = SobelowRun.run(env)
    assert output == @output
    assert [%{"type" => "SQL Injection", "file" => "lib/example.ex"}] = findings

    assert {:ok, payload} = Analysis.run(%{root: root}, "sobelow")
    wire_payload = payload |> Jason.encode!() |> Jason.decode!()
    assert wire_payload["output"] == @output
    assert wire_payload["diagnostics"] == findings
    assert wire_payload["exit_status"] == 1
    assert :meck.validate(Local)
  end
end
