defmodule CmsHarness.Agents.Shell do
  @moduledoc """
  Runs an agent's bash command without the harness's own environment.

  Alloy's default bash tool inherits this BEAM's environment, so an agent
  running `mix test` in a project got the harness's `MIX_ENV=harness`, a
  config that project does not have, and every `CMS_*` variable naming this
  harness (the same leak that sent spex harnesses to the real server).

  ## Redirecting into the copy

  Issue b1345aaf's sibling, 13f276fb: restricted bash (`-r`) refuses every
  `>`/`>>`, including one aimed at the agent's own checkout, where writing a
  validation log is ordinary and not an escape. John's decision: allow that
  one case, and nothing else -- we own this tool now.

  Rather than drop `-r` (which would also lift its `cd`, `PATH`/`SHELL`/
  `ENV`/`BASH_ENV` and slash-command guards for the whole command), a safe
  `>`/`>>` clause whose target resolves inside `dir` is stripped before
  bash runs. This module writes captured output to the target. It also
  accepts simple semicolon chains by running each segment in order after
  validating every redirect. Unsupported redirects remain refused, and
  shell refusals are returned as errors even when a later command would
  otherwise hide the failing exit status.
  """

  alias CmsHarness.Agents.Engine.Execution
  alias CmsHarness.Agents.Engine.ProcessGroups
  alias CmsHarness.Config

  # Greedy on the command so a string with more than one `>` lands the split
  # on the rightmost one; `extract_safe_redirect/2` then refuses a cmd that
  # still contains `>` rather than guess which one the agent meant. The
  # target's own character class excludes everything that could make it mean
  # something other than a literal path (quotes, `$`, backticks, the shell's
  # own control characters, `~`), and the `2>&1` tail is accepted and
  # discarded since output here is already merged (`stderr_to_stdout: true`).
  @redirect_pattern ~r/
    \A(.+)                                   # the command
    [ \t]+(>{1,2})[ \t]*                      # > or >>
    ([^\s'"`$;&|<>()~][^\s'"`$;&|<>()]*)      # the target
    (?:[ \t]+2>&1)?[ \t]*\z
  /xs

  @doc "Runs a command without a deadline, returning its output and exit status."
  @spec run(String.t(), String.t() | nil) :: {String.t(), non_neg_integer()}
  def run(command, dir) do
    opts = [stderr_to_stdout: true, env: Config.scrubbed_env()]
    opts = if dir, do: Keyword.put(opts, :cd, dir), else: opts

    System.cmd("bash", ["-rc", command], opts)
  end

  @doc "Runs with a deadline, retaining output even when the executor times out."
  def run(command, dir, timeout) do
    case compound_redirects(command, dir) do
      {:ok, segments} ->
        run_segments(segments, dir, timeout)

      {:error, reason} ->
        {:error, "Restricted shell refused command: #{reason}\nexit code: 1"}

      :not_compound ->
        case extract_safe_redirect(command, dir) do
          {:redirect, clean_command, target, mode} ->
            with_redirect(clean_command, dir, timeout, target, mode)

          :none ->
            plain(command, dir, timeout)
        end
    end
  end

  defp plain(command, dir, timeout) do
    case execute(command, dir, timeout) do
      {:ok, output, exit_code} ->
        result = "#{output}\nexit code: #{exit_code}"
        if restricted_refusal?(output), do: {:error, result}, else: {:ok, result}

      {:crash, output, reason} ->
        crashed(output, reason)

      {:timeout, output, cleanup} ->
        timed_out(output, timeout, cleanup)
    end
  end

  # The command handed to bash never contains the redirect, so it is exactly
  # as restricted as `plain/3` -- only the writing of its output is new.
  defp with_redirect(command, dir, timeout, target, mode) do
    case execute(command, dir, timeout) do
      {:ok, output, exit_code} ->
        redirected_result(target, output, exit_code, mode)

      {:crash, output, reason} ->
        crashed(output, reason)

      {:timeout, output, cleanup} ->
        timed_out(output, timeout, cleanup)
    end
  end

  defp redirected_result(target, output, exit_code, mode) do
    case write_redirect(target, output, mode) do
      :ok ->
        reply =
          "Output written to #{target} (#{byte_size(output)} bytes).\nexit code: #{exit_code}"

        if restricted_refusal?(output), do: {:error, reply}, else: {:ok, reply}

      {:error, reason} ->
        {:error,
         "#{output}\nexit code: #{exit_code}\n\nCould not write #{target}: " <>
           "#{:file.format_error(reason)}"}
    end
  end

  # A small, unambiguous subset of semicolon chains can be run segment by
  # segment. Reject a chain with an unsupported redirect before running any
  # segment, so a later successful command cannot mask bash's refusal.
  defp compound_redirects(command, dir) do
    if String.contains?(command, ";") and String.contains?(command, ">") and
         not String.contains?(command, ["'", "\"", "`", "$", "\\", "&", "|", "(", ")", "<", "\n"]) do
      segments = String.split(command, ";", trim: true) |> Enum.map(&String.trim/1)

      cond do
        segments == [] ->
          {:error, "empty command chain"}

        Enum.any?(segments, fn segment ->
          String.contains?(segment, ">") and extract_safe_redirect(segment, dir) == :none
        end) ->
          {:error, "redirect target is outside the working copy or unsupported"}

        true ->
          {:ok, segments}
      end
    else
      :not_compound
    end
  end

  defp run_segments(segments, dir, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Enum.reduce_while(segments, {:ok, []}, fn segment, {:ok, replies} ->
      remaining = max(deadline - System.monotonic_time(:millisecond), 1)

      result =
        case extract_safe_redirect(segment, dir) do
          {:redirect, clean, target, mode} -> with_redirect(clean, dir, remaining, target, mode)
          :none -> plain(segment, dir, remaining)
        end

      case result do
        {:ok, reply} -> {:cont, {:ok, [reply | replies]}}
        {:error, reply} -> {:halt, {:error, Enum.join(Enum.reverse([reply | replies]), "\n")}}
      end
    end)
    |> then(fn
      {:ok, replies} -> {:ok, Enum.join(Enum.reverse(replies), "\n")}
      error -> error
    end)
  end

  defp restricted_refusal?(output),
    do: Regex.match?(~r/(?:^|\n)[^\n]*bash: line \d+: [^\n]*restricted\b/, output)

  defp write_redirect(target, output, :truncate), do: File.write(target, output)
  defp write_redirect(target, output, :append), do: File.write(target, output, [:append])

  defp crashed(output, reason), do: {:error, "Executor crashed: #{inspect(reason)}\n#{output}"}

  defp timed_out(output, timeout, cleanup) do
    {:error,
     "Command timed out after #{timeout}ms. #{cleanup_status(cleanup)}\n" <>
       "Partial output follows:\n#{output}"}
  end

  # `{:ok, output, exit_code}` on completion, `{:timeout, partial, cleanup}`
  # if the deadline passed first, `{:crash, partial, reason}` if the task
  # itself died. Shared by `plain/3` and `with_redirect/5` so both read the
  # same captured bytes regardless of what happens to them afterward.
  defp execute(command, dir, timeout) do
    {:ok, capture} = StringIO.open("")

    try do
      opts = [
        stderr_to_stdout: true,
        env: Config.scrubbed_env(),
        into: IO.binstream(capture, :line)
      ]

      opts = if dir, do: Keyword.put(opts, :cd, dir), else: opts

      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          System.cmd("bash", ["-rc", command], opts)
        end)

      case Task.yield(task, timeout) do
        nil ->
          cleanup = stop_and_drain(task)
          {_, output} = StringIO.contents(capture)
          {:timeout, output, cleanup}

        {:ok, {_, exit_code}} ->
          {_, output} = StringIO.contents(capture)
          {:ok, output, exit_code}

        {:exit, reason} ->
          {_, output} = StringIO.contents(capture)
          {:crash, output, reason}
      end
    after
      StringIO.close(capture)
    end
  end

  # Capture ownership while frozen, but keep the System.cmd reader alive while
  # stopping its OS group. Killing that reader first discards port messages
  # that have arrived but have not yet been written to StringIO.
  defp stop_and_drain(task) do
    ownership = Execution.capture(task.pid)
    deadline = System.monotonic_time(:millisecond) + 5_000

    try do
      case ownership.groups do
        [] ->
          Execution.release(ownership)
          Task.shutdown(task, :brutal_kill)
          :ok

        groups ->
          term_result = ProcessGroups.signal(groups, "-TERM", deadline)
          Enum.each(ownership.owners, &resume_reader/1)
          Process.sleep(min(100, max(deadline - System.monotonic_time(:millisecond), 0)))
          kill_result = ProcessGroups.signal(groups, "-KILL", deadline)
          confirmation = ProcessGroups.confirm(groups, deadline)

          # System.cmd consumes data preceding exit_status before returning.
          # Await that return before reading StringIO, even if cleanup failed.
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)
          Task.yield(task, remaining) || Task.shutdown(task, :brutal_kill)

          case confirmation do
            :ok -> :ok
            error -> {:error, {:cleanup_incomplete, error, term_result, kill_result}}
          end
      end
    after
      Execution.release(ownership)
    end
  end

  defp resume_reader(pid) do
    :erlang.resume_process(pid)
  rescue
    ArgumentError -> :ok
  end

  defp cleanup_status(:ok), do: "Local command subprocess termination confirmed."

  defp cleanup_status({:error, reason}),
    do: "Local command subprocess termination unconfirmed: #{inspect(reason)}."

  # `:none` on anything but a single trailing `>`/`>>` whose target resolves
  # inside `dir` -- a second `>` left in the stripped command, a target the
  # pattern cannot read as a plain path, or one that resolves outside `dir`
  # all fall back to handing bash the command unchanged, which refuses it
  # exactly as it always has.
  @spec extract_safe_redirect(String.t(), String.t() | nil) ::
          {:redirect, String.t(), String.t(), :truncate | :append} | :none
  defp extract_safe_redirect(command, dir) when is_binary(dir) and dir != "" do
    with [_, cmd, op, target] <- Regex.run(@redirect_pattern, command),
         false <- String.contains?(cmd, ">"),
         trimmed_cmd <- String.trim(cmd),
         true <- trimmed_cmd != "",
         root <- Path.expand(dir),
         expanded <- Path.expand(target, dir),
         true <- expanded == root or String.starts_with?(expanded, root <> "/") do
      mode = if op == ">>", do: :append, else: :truncate
      {:redirect, trimmed_cmd, expanded, mode}
    else
      _ -> :none
    end
  end

  defp extract_safe_redirect(_command, _dir), do: :none
end
