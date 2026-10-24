defmodule CodeMySpec.Analysis.Tools.PagingThroughAScriptTest do
  @moduledoc """
  ad6c7674. An agent paging a run's output from a script got `output` nil for
  every offset but 0 and the exact tail, with `output_available` true. A script
  reads the page the way an agent does, so this pages a realistic multi-chunk
  failure from offset 0 to the end and reassembles it byte for byte.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpecSpex.CriterionScript

  # ANSI colours, multi-byte text, quotes, backslashes, stack-trace lines.
  @chunk "\e[31m  1) test \"it works\" (Some.Test)\e[0m\n     left:  \"α\\n🙂\"\n     right: %{a: 1}\n       test/x_test.exs:42: (test)\n"

  setup do
    scope = full_scope_fixture()
    output = String.duplicate(@chunk, 120)
    run = analysis_run_fixture(scope, %{source: "exunit", kind: :partial})
    {:ok, run} = RunsRepository.finish_run(run, :completed, %{output: output, exit_status: 2})
    %{scope: scope, run: run, output: output}
  end

  # The whole run, paged from a script at the fixed limit: concatenated, the
  # slices are the output byte for byte.
  test "a script reads every page of a multi-chunk run and reassembles it exactly", ctx do
    assert String.length(ctx.output) > 10_000

    %{text: text} =
      CriterionScript.run(ctx.scope, """
      local out, offset, pages = {}, 0, 0
      while offset ~= nil do
        local r = get_analysis_output({ run_id = #{ctx.run.id}, offset = offset, limit = 2000 })
        if r.output == nil then return "NO OUTPUT at offset " .. offset end
        table.insert(out, r.output)
        offset = r.next_offset
        pages = pages + 1
      end
      return { pages = pages, output = table.concat(out) }
      """)

    refute text =~ "NO OUTPUT", text
    decoded = text |> String.replace_prefix("Returned:\n", "") |> Jason.decode!()
    assert decoded["pages"] == ceil(String.length(ctx.output) / 2000)
    assert decoded["output"] == ctx.output
  end

  test "the tool's text answer is unchanged for a direct caller", ctx do
    {:ok, text} =
      CodeMySpec.ToolLibrary.run(
        "get_analysis_output",
        %{run_id: ctx.run.id, offset: 4000},
        %{scope: ctx.scope}
      )

    assert %{"output" => out, "output_available" => true} = Jason.decode!(text)
    assert out == String.slice(ctx.output, 4000, 2000)
  end
end
