defmodule CmsHarness.Setup.Step do
  @moduledoc "A recorded machine setup attempt, independent of project requirements."

  @derive Jason.Encoder
  @enforce_keys [:key, :position]
  defstruct [
    :key,
    :position,
    :started_at,
    :finished_at,
    :error,
    state: :not_started,
    commands: []
  ]

  @type state :: :not_started | :running | :done | :errored | :paused
  @type command_result :: %{
          command: String.t(),
          args: [String.t()],
          output: String.t(),
          exit_status: integer() | nil,
          error: String.t() | nil
        }
  @type t :: %__MODULE__{
          key: String.t(),
          position: non_neg_integer(),
          state: state(),
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          error: String.t() | nil,
          commands: [command_result()]
        }

  @spec new(String.t(), non_neg_integer()) :: t()
  def new(key, position) when is_binary(key) and is_integer(position) and position >= 0 do
    %__MODULE__{key: key, position: position}
  end

  @spec start(t(), DateTime.t()) :: t()
  def start(%__MODULE__{state: :not_started} = step, %DateTime{} = now) do
    %{step | state: :running, started_at: now}
  end

  @spec record_command(t(), command_result()) :: t()
  def record_command(
        %__MODULE__{state: :running} = step,
        %{command: command, args: args, output: output, exit_status: status, error: error} =
          result
      )
      when is_binary(command) and is_list(args) and is_binary(output) and
             (is_integer(status) or is_nil(status)) and
             (is_binary(error) or is_nil(error)) do
    %{step | commands: step.commands ++ [result]}
  end

  @spec finish(t(), :ok | {:error, String.t()} | {:paused, String.t()}, DateTime.t()) :: t()
  def finish(%__MODULE__{state: :running} = step, :ok, %DateTime{} = now) do
    %{step | state: :done, finished_at: now, error: nil}
  end

  def finish(%__MODULE__{state: :running} = step, {:error, reason}, %DateTime{} = now)
      when is_binary(reason) do
    %{step | state: :errored, finished_at: now, error: reason}
  end

  def finish(%__MODULE__{state: :running} = step, {:paused, instructions}, %DateTime{} = now)
      when is_binary(instructions) do
    %{step | state: :paused, finished_at: now, error: instructions}
  end
end
