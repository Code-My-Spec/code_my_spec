defmodule CodeMySpecSpex.TerminalAgentHelpers do
  @moduledoc """
  A Claude Code session in a person's terminal, driven through what it really
  uses (stories 1122-1124): the plugin's SessionStart hook on a live harness,
  and the tools an agent calls.

      context = HarnessHooks.ensure_live_harness(context)
      body = start_session(context, session_id())
      [%{"role" => "main"}] = agents(context)
  """

  import ExUnit.Assertions, only: [assert: 1]

  alias CmsHarnessTest.ClaudeSessions
  alias CodeMySpec.ToolLibrary
  alias CodeMySpecSpex.HarnessHooks

  @doc "A Claude Code session id nobody else has."
  @spec session_id() :: String.t()
  def session_id, do: "cc-#{System.unique_integer([:positive])}"

  @doc """
  What the plugin sends when a session opens on the live harness's checkout,
  and the hook's answer.
  """
  @spec start_session(map(), String.t(), map()) :: map()
  def start_session(context, session_id, extra \\ %{}) do
    HarnessHooks.post_hook(
      context,
      "session-start",
      Map.merge(%{"session_id" => session_id, "source" => "startup"}, extra)
    )
  end

  @doc "The project's agents as `list_agents` gives them to a script."
  @spec agents(map()) :: [map()]
  def agents(context) do
    {:ok, rows} = ToolLibrary.data("list_agents", %{}, %{scope: context.scope})
    rows
  end

  @doc "The agent a session joined as, from the project's listing."
  @spec agent_for(map(), map()) :: map() | nil
  def agent_for(context, %{"agent_id" => id}),
    do: Enum.find(agents(context), &(&1["id"] == id))

  @doc "A terminal agent taking a role, as it does with `set_my_role`."
  @spec set_role(map(), String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def set_role(context, session_id, role),
    do:
      ToolLibrary.run("set_my_role", %{"role" => role, "session_id" => session_id}, %{
        scope: context.scope
      })

  @doc """
  A stand-in for a session's inbox: a real Unix socket whose every line is
  sent to the calling process as `{:inbox, decoded}`. Answers its path; it is
  removed when the test exits. Short, because socket paths cap near 104 bytes.
  """
  @spec open_inbox() :: %{socket: String.t(), listener: port()}
  def open_inbox do
    test = self()
    dir = Path.join(System.tmp_dir!(), "in#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    socket = Path.join(dir, "s.sock")

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, {:ifaddr, {:local, socket}}, active: false, packet: :line])

    spawn(fn -> accept(listener, test) end)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    %{socket: socket, listener: listener}
  end

  defp accept(listener, test), do: accepted(:gen_tcp.accept(listener), listener, test)

  defp accepted({:ok, conn}, listener, test) do
    read(conn, test)
    accept(listener, test)
  end

  defp accepted({:error, _}, _listener, _test), do: :ok

  defp read(conn, test), do: line(:gen_tcp.recv(conn, 0, 5_000), conn, test)

  defp line({:ok, line}, conn, test) do
    send(test, {:inbox, Jason.decode!(line)})
    read(conn, test)
  end

  defp line({:error, _}, _conn, _test), do: :ok

  @doc """
  A session opening with an inbox socket, as Claude Code runs one: it writes
  its session registry file (`<pid>.json`, naming the socket) and fires the
  plugin's SessionStart command hook, which carries only the session id.
  `:status` is what Claude Code says of the session (default `idle`);
  `:transcript` the path its transcript is written to.
  """
  @spec start_session_on_socket(map(), String.t(), String.t(), keyword()) :: map()
  def start_session_on_socket(context, session_id, socket, opts \\ []) do
    status = Keyword.get(opts, :status, "idle")
    ClaudeSessions.put(session_id, status)
    register_session(session_id, socket, status)

    payload =
      %{"session_id" => session_id, "source" => "startup", "permission_mode" => "default"}
      |> put_present("transcript_path", Keyword.get(opts, :transcript))

    case HarnessHooks.post_hook(context, "session-start", payload) do
      %{"agent_id" => id} = answer when is_binary(id) and id != "" ->
        answer

      answer ->
        raise "session-start did not register #{session_id}: #{inspect(answer)}"
    end
  end

  @doc """
  Waits until a started session is present: direct messages travel only over
  the native transport, so a message sent before presence is refused.
  """
  @spec await_present(map(), String.t()) :: :ok
  def await_present(context, agent_id) do
    CodeMySpecSpex.Case.eventually(fn ->
      assert MapSet.member?(CodeMySpec.Agents.present_ids(context.scope), agent_id)
    end)

    :ok
  end

  # Claude Code's own session registry, in the directory the test config names.
  defp register_session(session_id, socket, status) do
    dir = Path.join(Application.fetch_env!(:code_my_spec, :claude_config_dir), "sessions")
    File.mkdir_p!(dir)
    path = Path.join(dir, "#{System.unique_integer([:positive])}.json")

    File.write!(
      path,
      Jason.encode!(%{
        "sessionId" => session_id,
        "status" => status,
        "messagingSocketPath" => socket,
        "version" => "2.1.302"
      })
    )

    ExUnit.Callbacks.on_exit(fn -> File.rm(path) end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  @doc "The developer submitting a prompt: the session's UserPromptSubmit hook fires (story 1127)."
  @spec submit_prompt(map(), String.t()) :: map()
  def submit_prompt(context, session_id),
    do: HarnessHooks.post_hook(context, "user-prompt-submit", %{"session_id" => session_id})

  @doc "The session finishing its turn: its Stop hook fires (story 1127)."
  @spec stop_turn(map(), String.t()) :: map()
  def stop_turn(context, session_id),
    do: HarnessHooks.post_hook(context, "stop", %{"session_id" => session_id})

  @doc "What Claude Code's agent list says of a session from now on."
  @spec session_is(String.t(), String.t()) :: :ok
  def session_is(session_id, status), do: ClaudeSessions.put(session_id, status)

  @doc "The developer closing the terminal: the session leaves the list and its socket."
  @spec close_session(String.t(), %{listener: port(), socket: String.t()}) :: :ok
  def close_session(session_id, %{listener: listener, socket: socket}) do
    ClaudeSessions.gone(session_id)
    :gen_tcp.close(listener)
    File.rm(socket)
    :ok
  end

  @doc "The harness looking at a terminal agent's session now (`ClaudeSessions.look/1`)."
  @spec look(String.t()) :: :ok
  defdelegate look(agent_id), to: ClaudeSessions

  @doc "A directory no project serves, removed when the test exits."
  @spec not_a_checkout() :: String.t()
  def not_a_checkout do
    dir = Path.join(System.tmp_dir!(), "not-a-checkout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  @doc """
  Where a session's transcript is written, empty for now: Claude Code's
  `~/.claude/projects/<cwd>/<session>.jsonl`, in a directory removed on exit.
  """
  @spec transcript_for(String.t()) :: String.t()
  def transcript_for(session_id) do
    dir = Path.join(System.tmp_dir!(), "tr#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf!(dir) end)
    path = Path.join(dir, "#{session_id}.jsonl")
    File.write!(path, "")
    path
  end

  @doc "Claude Code writing one entry to a session's transcript."
  @spec write_transcript(String.t(), map()) :: :ok
  def write_transcript(path, entry),
    do: File.write!(path, Jason.encode!(entry) <> "\n", [:append])

  @doc "Whether any file in the checkout at `root` contains `text`."
  @spec checkout_mentions?(String.t(), String.t()) :: boolean()
  def checkout_mentions?(root, text) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.any?(&(File.regular?(&1) and File.read!(&1) =~ text))
  end
end
