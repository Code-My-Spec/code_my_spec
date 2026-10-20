defmodule CodeMySpecSpex.TerminalCodexHelpers do
  @moduledoc """
  A Codex session in a person's terminal, driven through what it really uses
  (story 1128): the Codex plugin's hooks on a live harness, and the `codex`
  binary the harness queues messages with.

  The binary is a stand-in script the harness is told to run, so what Codex
  would be asked to queue is read from its log rather than from a live Codex:

      fake = install_fake_codex()
      started = start_codex_session(context, codex_session_id())
      [%{thread: thread, message: "Rebase."}] = codex_queued(fake)
  """

  alias CodeMySpecSpex.HarnessHooks

  @engine_header {"x-agent-engine", "codex"}

  @doc "A Codex session (thread) id nobody else has: a UUID, as Codex names them."
  @spec codex_session_id() :: String.t()
  def codex_session_id do
    n = System.unique_integer([:positive])

    "01a" <>
      String.pad_leading(Integer.to_string(n, 16), 5, "0") <> "-1760-7a30-840d-f6bac54e0b89"
  end

  @doc """
  What the Codex plugin's hook sends when a session opens on the live
  harness's checkout, and the hook's answer. The plugin's `bin/hook` names the
  engine in `X-Agent-Engine`; Codex's payload carries its `model`.
  """
  @spec start_codex_session(map(), String.t(), map()) :: map()
  def start_codex_session(context, session_id, extra \\ %{}) do
    codex_hook(
      context,
      "session-start",
      session_id,
      Map.merge(%{"hook_event_name" => "SessionStart", "source" => "startup"}, extra)
    )
  end

  @doc "Any hook of a Codex session, as the Codex plugin posts it."
  @spec codex_hook(map(), String.t(), String.t(), map()) :: map()
  def codex_hook(context, hook, session_id, extra \\ %{}) do
    HarnessHooks.post_hook(
      context,
      hook,
      Map.merge(%{"session_id" => session_id, "model" => "gpt-5-codex"}, extra),
      [@engine_header]
    )
  end

  @doc "The developer submitting a prompt to a Codex session."
  @spec codex_submit_prompt(map(), String.t()) :: map()
  def codex_submit_prompt(context, session_id),
    do: codex_hook(context, "user-prompt-submit", session_id, %{"prompt" => "Take the task."})

  @doc "A Codex session finishing its turn: its Stop hook fires."
  @spec codex_stop_turn(map(), String.t()) :: map()
  def codex_stop_turn(context, session_id), do: codex_hook(context, "stop", session_id)

  @doc """
  Put a stand-in `codex` on the harness's machine. It records every
  `codex queue --thread <id> --message <text>` it is run with. With
  `queue: false` it is a Codex too old to have the command: `queue` is an
  unrecognized subcommand and exits non-zero.
  """
  @spec install_fake_codex(keyword()) :: %{log: String.t(), bin: String.t()}
  def install_fake_codex(opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "codex#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    log = Path.join(dir, "queued.log")
    bin = Path.join(dir, "codex")
    File.write!(bin, script(log, Keyword.get(opts, :queue, true)))
    File.chmod!(bin, 0o755)

    previous = Application.get_env(:cms_harness, :codex_command)
    Application.put_env(:cms_harness, :codex_command, bin)

    ExUnit.Callbacks.on_exit(fn ->
      restore(previous)
      File.rm_rf!(dir)
    end)

    %{log: log, bin: bin}
  end

  defp restore(nil), do: Application.delete_env(:cms_harness, :codex_command)
  defp restore(previous), do: Application.put_env(:cms_harness, :codex_command, previous)

  defp script(log, true) do
    """
    #!/bin/sh
    if [ "$1" = "queue" ]; then
      shift
      thread=""; message=""
      while [ $# -gt 0 ]; do
        case "$1" in
          --thread) thread="$2"; shift 2 ;;
          --message) message="$2"; shift 2 ;;
          *) shift ;;
        esac
      done
      if [ -n "$message" ]; then
        printf '%s\\t%s\\0' "$thread" "$message" >> '#{log}'
      fi
      exit 0
    fi
    exit 0
    """
  end

  defp script(_log, false) do
    """
    #!/bin/sh
    if [ "$1" = "queue" ]; then
      echo "error: unrecognized subcommand 'queue'" >&2
      exit 2
    fi
    exit 0
    """
  end

  @doc "Forget what the stand-in `codex` was asked to queue so far: what came before the scenario."
  @spec forget_queued(%{log: String.t()}) :: :ok
  def forget_queued(%{log: log}) do
    File.rm(log)
    :ok
  end

  @doc "What the stand-in `codex` was asked to queue, oldest first."
  @spec codex_queued(%{log: String.t()}) :: [%{thread: String.t(), message: String.t()}]
  def codex_queued(%{log: log}) do
    case File.read(log) do
      {:ok, body} ->
        body
        |> String.split("\0", trim: true)
        |> Enum.map(fn line ->
          [thread, message] = String.split(line, "\t", parts: 2)
          %{thread: thread, message: message}
        end)

      {:error, :enoent} ->
        []
    end
  end
end
