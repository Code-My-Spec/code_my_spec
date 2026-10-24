defmodule CmsHarness.Setup.Command do
  @moduledoc "Executes a machine prerequisite command and preserves its diagnostic result."

  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CmsHarness.Setup.Step

  @spec run(String.t(), String.t(), [String.t()]) :: Step.command_result()
  def run(cwd, command, args)
      when is_binary(cwd) and is_binary(command) and is_list(args) do
    Enum.each(args, &validate_argument!/1)
    execute(ExecutionContext.new(:local, cwd), command, args)
  end

  @spec successful?(Step.command_result()) :: boolean()
  def successful?(%{exit_status: 0, error: nil}), do: true
  def successful?(_result), do: false

  defp execute(environment, command, args) do
    {output, status} =
      ExecutionContexts.cmd(environment, command, args, stderr_to_stdout: true)

    %{
      command: command,
      args: args,
      output: output,
      exit_status: status,
      error: exit_error(command, status)
    }
  rescue
    exception in [ErlangError] ->
      %{
        command: command,
        args: args,
        output: "",
        exit_status: nil,
        error: "Could not run #{command}: #{Exception.message(exception)}"
      }
  end

  defp exit_error(_command, 0), do: nil
  defp exit_error(command, status), do: "#{command} exited with status #{status}"

  defp validate_argument!(argument) when is_binary(argument), do: :ok

  defp validate_argument!(_argument),
    do: raise(ArgumentError, "command arguments must be strings")
end
