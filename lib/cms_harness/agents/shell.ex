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
  `ENV`/`BASH_ENV` and slash-command guards for the whole command), a single
  trailing `>`/`>>` clause whose target resolves inside `dir` is stripped
  before the command ever reaches bash. The command that *is* handed to
  bash never contains a redirect, so it runs exactly as restricted as
  always; this module writes the captured output to the target itself,
  which is also truer to what a real redirect does -- the output goes to
  the file, not back to the caller. Anything else (no trailing clause, a
  target outside `dir`, more than one `>` in the command) runs unchanged,
  letting bash's own refusal stand.
  """

  alias CmsHarness.Agents.Engine.Execution
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
    case extract_safe_redirect(command, dir) do
      {:redirect, clean_command, target, mode} ->
        with_redirect(clean_command, dir, timeout, target, mode)

      :none ->
        plain(command, dir, timeout)
    end
  end

  defp plain(command, dir, timeout) do
    case execute(command, dir, timeout) do
      {:ok, output, exit_code} -> {:ok, "#{output}\nexit code: #{exit_code}"}
      {:crash, output, reason} -> crashed(output, reason)
      {:timeout, output, cleanup} -> timed_out(output, timeout, cleanup)
    end
  end

  # The command handed to bash never contains the redirect, so it is exactly
  # as restricted as `plain/3` -- only the writing of its output is new.
  defp with_redirect(command, dir, timeout, target, mode) do
    case execute(command, dir, timeout) do
      {:ok, output, exit_code} ->
        case write_redirect(target, output, mode) do
          :ok ->
            {:ok,
             "Output written to #{target} (#{byte_size(output)} bytes).\nexit code: #{exit_code}"}

          {:error, reason} ->
            {:error,
             "#{output}\nexit code: #{exit_code}\n\nCould not write #{target}: " <>
               "#{:file.format_error(reason)}"}
        end

      {:crash, output, reason} ->
        crashed(output, reason)

      {:timeout, output, cleanup} ->
        timed_out(output, timeout, cleanup)
    end
  end

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
          cleanup = Execution.stop_and_release(task.pid)
          Task.shutdown(task, :brutal_kill)
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
