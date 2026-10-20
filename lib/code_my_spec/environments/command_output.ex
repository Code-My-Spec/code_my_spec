defmodule CodeMySpec.Environments.CommandOutput do
  @moduledoc "Streams command output to a caller-owned IO device while retaining the return value."
  defstruct [:device]

  defimpl Collectable do
    def into(%{device: device}) do
      {[],
       fn
         chunks, {:cont, bytes} ->
           :ok = IO.binwrite(device, bytes)
           [bytes | chunks]

         chunks, :done ->
           chunks |> Enum.reverse() |> IO.iodata_to_binary()

         _chunks, :halt ->
           :ok
       end}
    end
  end
end
