defmodule CodeMySpecSpex.HarnessedKnowledgeHelpers do
  @moduledoc """
  A checkout on a harness, for stories 688 and 689 (577de9bb step 5): a copy
  with its files on disk here, a scope addressed to it the way the channel
  addresses one, and a harness answering the server's file reads from that
  disk. Taking the harness down is the offline case.
  """

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import ExUnit.Assertions

  alias Anubis.Server.Frame
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.McpServers.Knowledge.Tools.SemanticSearch
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecSpex.Fixtures

  @knowledge ".code_my_spec/knowledge"

  @doc "A checkout of the project, its scope and its directory. `main?: true` designates it."
  @spec checkout(map(), keyword()) :: map()
  def checkout(context, opts \\ []) do
    dir = CodeMySpec.TempFile.owned_dir("test")

    {:ok, copy} =
      WorkingCopies.issue(context.scope, nil,
        label: "checkout #{System.unique_integer([:positive])}",
        device: Fixtures.device_fixture(context.scope)
      )

    {:ok, copy} = WorkingCopies.report_root(copy, dir)
    designate(context.scope, copy, Keyword.get(opts, :main?, false))
    %{scope: WorkingCopies.put_scope(context.scope, copy), dir: dir}
  end

  defp designate(scope, copy, true), do: {:ok, _} = WorkingCopies.designate_main(scope, copy.id)
  defp designate(_scope, _copy, false), do: :ok

  @doc """
  The checkout's harness, up: it answers the server's `read_file` requests
  from the checkout's directory and tells the calling process `{:harness_read, path}`.
  """
  @spec harness_up(map()) :: pid()
  def harness_up(%{scope: scope, dir: dir}) do
    test = self()

    pid =
      spawn(fn ->
        {:ok, _} = Registry.register(HarnessRegistry, scope.active_working_copy_id, :spex)
        send(test, :harness_up)
        answer(dir, scope.active_working_copy_id, test)
      end)

    assert_receive :harness_up
    pid
  end

  defp answer(dir, key, test) do
    receive do
      {:"$gen_call", from, {:fs_request, "read_file", %{"path" => path}}} ->
        send(test, {:harness_read, path})
        GenServer.reply(from, File.read(Path.join(dir, path)))
        answer(dir, key, test)

      {:down, caller} ->
        Registry.unregister(HarnessRegistry, key)
        send(caller, :harness_down)
    end
  end

  @doc "The harness goes offline."
  @spec harness_down(pid()) :: :ok
  def harness_down(pid) do
    send(pid, {:down, self()})
    assert_receive :harness_down
    :ok
  end

  @doc "Write a knowledge file into the checkout."
  @spec write_knowledge(map(), String.t(), String.t()) :: :ok
  def write_knowledge(%{dir: dir}, name, content) do
    path = Path.join([dir, @knowledge, name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  @doc "Delete a knowledge file from the checkout."
  @spec remove_knowledge(map(), String.t()) :: :ok
  def remove_knowledge(%{dir: dir}, name), do: File.rm!(Path.join([dir, @knowledge, name]))

  @doc "Write a one-module source file at `path` in the checkout."
  def write_code(%{dir: dir}, path, module) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, "defmodule #{module} do\n  @moduledoc false\nend\n")
  end

  @doc "Delete `path` from the checkout."
  def remove_code(%{dir: dir}, path), do: File.rm!(Path.join(dir, path))

  @doc "Write the checkout's `mix.lock`."
  @spec write_lock(map(), String.t()) :: :ok
  def write_lock(%{dir: dir}, content), do: File.write!(Path.join(dir, "mix.lock"), content)

  @doc "The checkout's harness sends its manifest, scanned from the checkout's disk."
  @spec manifest(map()) :: term()
  def manifest(%{scope: scope, dir: dir}), do: Fixtures.deliver_manifest(scope, observe_in: dir)

  @doc "`semantic_search` text for `source`, as an agent on the project gets it."
  @spec search(map(), String.t()) :: String.t()
  def search(%{scope: scope}, source) do
    {:reply, response, _} =
      SemanticSearch.execute(
        %{query: "what we decided", source: source, limit: 50},
        %Frame{assigns: %{current_scope: scope}}
      )

    refute response.isError, response_text(response)
    response_text(response)
  end

  @doc "The knowledge file names project-knowledge search cites."
  @spec knowledge_found(map()) :: [String.t()]
  def knowledge_found(checkout) do
    ~r/^\*\*project_knowledge\/\.code_my_spec\/knowledge\/(.+?)\*\*/m
    |> Regex.scan(search(checkout, "project_knowledge"), capture: :all_but_first)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Paths the harness was asked to read since the last drain."
  @spec reads() :: [String.t()]
  def reads, do: drain_reads([])

  defp drain_reads(acc) do
    receive do
      {:harness_read, path} -> drain_reads(acc ++ [path])
    after
      0 -> acc
    end
  end

  @doc "Embedding batch texts reported since the last drain."
  @spec embedded() :: [String.t()]
  def embedded, do: drain_embedded([])

  defp drain_embedded(acc) do
    receive do
      {:embedded, texts, _priority} -> drain_embedded(acc ++ texts)
    after
      0 -> acc
    end
  end
end
