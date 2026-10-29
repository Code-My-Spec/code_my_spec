defmodule CmsHarness.Agents.Tools.RunScriptSpillTest do
  use CodeMySpecTest.DataCase, async: false
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.{Frame, Response}
  alias CmsHarness.Agents.Tools.{RunScript, Read}
  alias CodeMySpec.McpServers.CodeMode.Tools.RunScript, as: ServerRunScript

  @moduletag :tmp_dir

  defmodule Transport do
    def call(%{frame: frame}, "run_script", args) do
      params = %{script: args["script"], client_shapes_output: args["client_shapes_output"]}
      {:reply, response, _} = ServerRunScript.execute(params, frame)

      text =
        response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")

      reply(response.isError, text)
    end

    defp reply(true, text), do: {:error, text}
    defp reply(false, text), do: {:ok, text}
  end

  setup %{tmp_dir: root} do
    previous = Application.get_env(:code_my_spec, :harness_mcp_transport)
    Application.put_env(:code_my_spec, :harness_mcp_transport, Transport)
    on_exit(fn -> Application.put_env(:code_my_spec, :harness_mcp_transport, previous) end)
    frame = %Frame{assigns: %{current_scope: full_scope_fixture()}}
    spill = Path.join(root, "agent-one")

    %{
      frame: frame,
      context: %{
        mcp_client: %{frame: frame},
        spill_dir: spill,
        allowed_paths: [spill],
        working_directory: root
      }
    }
  end

  test "a large server reply is saved locally and readable only within that agent's scope", %{
    context: context,
    tmp_dir: root
  } do
    assert {:ok, notice} =
             RunScript.execute(
               %{"script" => ~S[return string.rep("x", 60000) .. "TAIL"]},
               context
             )

    assert [_, path] = Regex.run(~r/Full output saved to: (.+)/, notice)
    assert Path.dirname(path) == context.spill_dir
    assert File.read!(path) == "Returned:\n" <> String.duplicate("x", 60_000) <> "TAIL"

    assert {:ok, output} =
             Read.execute(%{"file_path" => path, "offset" => 1, "limit" => 1}, context)

    assert output =~ "Returned:"

    assert {:error, _} =
             Read.execute(%{"file_path" => path}, %{
               context
               | spill_dir: Path.join(root, "other"),
                 allowed_paths: [Path.join(root, "other")]
             })
  end

  test "large failures retain their error status and spill locally", %{context: context} do
    assert {:error, notice} =
             RunScript.execute(%{"script" => ~S|error(string.rep("bad", 20000))|}, context)

    assert [_, path] = Regex.run(~r/Full output saved to: (.+)/, notice)
    assert Path.dirname(path) == context.spill_dir
    assert File.read!(path) =~ String.duplicate("bad", 20_000)
  end

  test "without a local spill directory the fallback caps without a server file path", %{
    context: context
  } do
    assert {:ok, text} =
             RunScript.execute(
               %{"script" => ~S|return string.rep("x", 60000)|},
               Map.delete(context, :spill_dir)
             )

    assert byte_size(text) <= CodeMySpec.CodeMode.max_answer_bytes()
    assert text =~ "truncated"
    refute text =~ "written to"
  end

  test "ordinary MCP callers still get the model cap", %{frame: frame} do
    {:reply, response, _} =
      ServerRunScript.execute(%{script: ~S[return string.rep("x", 60000)]}, frame)

    text =
      response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")

    assert byte_size(text) <= CodeMySpec.CodeMode.max_answer_bytes()
    assert text =~ "truncated"
  end

  test "server transfer remains bounded even when client will shape it", %{frame: frame} do
    script = ~S|local xs = {}; for i=1,100 do xs[i]=string.rep("x", 20000) end; return xs|

    {:reply, response, _} =
      ServerRunScript.execute(%{script: script, client_shapes_output: true}, frame)

    text =
      response |> Response.to_protocol() |> Map.fetch!("content") |> hd() |> Map.fetch!("text")

    assert byte_size(text) <= 1_048_576
    assert text =~ "Transport limit reached"
  end
end
