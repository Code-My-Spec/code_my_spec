defmodule CodeMySpec.McpServers.Analysis.Tools.GetAnalysisOutputTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AnalysisFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.McpServers.Analysis.Tools.GetAnalysisOutput

  setup do
    scope = full_scope_fixture()
    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp finished(scope, source, output), do: finished(scope, source, output, :completed)

  defp finished(scope, source, output, status) do
    run = analysis_run_fixture(scope, %{source: source, kind: :partial})
    {:ok, run} = RunsRepository.finish_run(run, status, %{output: output, exit_status: 2})
    run
  end

  defp response(params, frame) do
    assert {:reply, response, ^frame} = GetAnalysisOutput.execute(params, frame)
    response
  end

  defp page(params, frame) do
    response = response(params, frame)
    assert response.isError == false
    [%{"text" => text}] = Response.to_protocol(response)["content"]
    Jason.decode!(text)
  end

  for source <- ~w(compiler credo exunit spex) do
    test "retains exact #{source} output including operands and stack traces", ctx do
      output = "\e[31mAssertion failed\e[0m\n  left:  α\n  right: β\n  test/example.exs:42\n"
      run = finished(ctx.scope, unquote(source), output)
      result = page(%{run_id: run.id}, ctx.frame)

      assert result["output"] == output
      assert result["run_id"] == run.id
      assert result["exit_status"] == 2
      assert result["output_available"] == true
      assert result["next_offset"] == nil
    end
  end

  test "pages reconstruct Unicode output and stay on the requested run", ctx do
    output = "á🙂\noriginal operands\n"
    run = finished(ctx.scope, "exunit", output)
    first = page(%{source: "exunit", limit: 2}, ctx.frame)
    finished(ctx.scope, "exunit", "a newer result")
    second = page(%{run_id: run.id, offset: first["next_offset"]}, ctx.frame)

    assert first["output"] == "á"
    assert first["next_offset"] == 2
    assert first["output"] <> second["output"] == output
    assert second["run_id"] == run.id
    assert second["next_offset"] == nil
  end

  test "a later superseded run does not shadow an earlier one with real output", ctx do
    run = finished(ctx.scope, "exunit", "the assertion that failed\n", :failed)
    newer = analysis_run_fixture(ctx.scope, %{source: "exunit", kind: :partial})

    {:ok, _superseded} =
      RunsRepository.finish_run(newer, :superseded, %{stats: %{"superseded" => "requeued"}})

    result = page(%{source: "exunit"}, ctx.frame)

    assert result["run_id"] == run.id
    assert result["output"] == "the assertion that failed\n"
    assert result["output_available"] == true
  end

  test "a source with nothing but a superseded run still answers with it", ctx do
    run = analysis_run_fixture(ctx.scope, %{source: "exunit", kind: :partial})

    {:ok, run} =
      RunsRepository.finish_run(run, :superseded, %{stats: %{"superseded" => "requeued"}})

    result = page(%{source: "exunit"}, ctx.frame)

    assert result["run_id"] == run.id
    assert result["status"] == "superseded"
    assert result["output_available"] == false
  end

  test "failed runs expose their retained boot error", ctx do
    run = finished(ctx.scope, "exunit", "** (RuntimeError) missing configuration\n", :failed)
    result = page(%{source: "exunit"}, ctx.frame)

    assert result["run_id"] == run.id
    assert result["status"] == "failed"
    assert result["output"] == "** (RuntimeError) missing configuration\n"
  end

  test "running without output is unavailable, not a successful empty result", ctx do
    run = analysis_run_fixture(ctx.scope)
    result = page(%{run_id: run.id}, ctx.frame)

    assert result["status"] == "running"
    assert result["output_available"] == false
    assert result["exit_status"] == nil
  end

  test "an empty retained result remains available", ctx do
    run = finished(ctx.scope, "compiler", "")
    result = page(%{run_id: run.id}, ctx.frame)

    assert result["output_available"] == true
    assert result["output"] == ""
    assert result["total_codepoints"] == 0
  end

  test "another working copy cannot read a run by id or source", ctx do
    run = finished(ctx.scope, "exunit", "private output")
    other = %{ctx.scope | active_working_copy_id: Ecto.UUID.generate()}
    frame = %Frame{assigns: %{current_scope: other}}

    assert response(%{run_id: run.id}, frame).isError
    assert response(%{source: "exunit"}, frame).isError
  end

  test "another project cannot read the run even with its working copy id", ctx do
    run = finished(ctx.scope, "exunit", "private output")
    other = %{full_scope_fixture() | active_working_copy_id: ctx.scope.active_working_copy_id}
    frame = %Frame{assigns: %{current_scope: other}}

    assert response(%{run_id: run.id}, frame).isError
  end

  test "a missing working copy never widens the query", ctx do
    run = finished(ctx.scope, "exunit", "private output")
    frame = %Frame{assigns: %{current_scope: %{ctx.scope | active_working_copy_id: nil}}}

    assert response(%{run_id: run.id}, frame).isError
  end

  test "rejects ambiguous selectors and invalid pagination", ctx do
    run = finished(ctx.scope, "exunit", "text")

    assert response(%{}, ctx.frame).isError
    assert response(%{run_id: run.id, source: "exunit"}, ctx.frame).isError
    assert response(%{source: "unknown"}, ctx.frame).isError
    assert response(%{run_id: run.id, offset: -1}, ctx.frame).isError
    assert response(%{run_id: run.id, offset: 5}, ctx.frame).isError
    assert response(%{run_id: run.id, limit: 2001}, ctx.frame).isError
    assert response(%{run_id: run.id, limit: 0}, ctx.frame).isError
  end

  test "a page fits the script response budget even with escaped controls", ctx do
    run = finished(ctx.scope, "exunit", String.duplicate("\u0001", 4000))
    response = response(%{run_id: run.id}, ctx.frame)
    [%{"text" => text}] = Response.to_protocol(response)["content"]

    assert byte_size(text) < CodeMySpec.CodeMode.max_answer_bytes()
    assert Jason.decode!(text)["next_offset"] == 2000
    assert Jason.decode!(text)["output"] == String.duplicate("\u0001", 2000)
  end
end
