defmodule CodeMySpec.Utils.Utf8 do
  @moduledoc """
  UTF-8-safe binary truncation.

  `binary_part/3` and friends cut at *byte* offsets, which can split a
  multi-byte UTF-8 character — e.g. an em-dash (`E2 80 94`) — and leave a
  partial, invalid byte sequence at the tail. That corrupt binary then
  crashes strict JSON encoders downstream: Anubis serializes MCP responses
  with Elixir's built-in encoder, which raises `{:invalid_byte, _}` and
  surfaces to the client as `-32603`.

  Use `valid_prefix/2` wherever text is truncated to a byte budget so the
  cut always lands on a UTF-8 character boundary.
  """

  @doc """
  Returns the longest prefix of `binary` that is valid UTF-8 and whose byte
  size does not exceed `max_bytes`.

  When a byte cut at `max_bytes` would land inside a multi-byte character,
  the trailing partial bytes are dropped so the result is always valid
  UTF-8. Assumes `binary` is itself valid UTF-8 (only the tail cut can
  introduce invalidity); for already-invalid input it still terminates.
  """
  @spec valid_prefix(binary(), non_neg_integer()) :: binary()
  def valid_prefix(binary, max_bytes)
      when is_binary(binary) and is_integer(max_bytes) and max_bytes >= 0 do
    if byte_size(binary) <= max_bytes do
      binary
    else
      binary
      |> binary_part(0, max_bytes)
      |> trim_partial_char()
    end
  end

  # A truncated UTF-8 character contributes at most 3 trailing bytes, so
  # this drops at most 3 bytes before the prefix is valid again.
  defp trim_partial_char(<<>>), do: <<>>

  defp trim_partial_char(chunk) do
    if String.valid?(chunk) do
      chunk
    else
      trim_partial_char(binary_part(chunk, 0, byte_size(chunk) - 1))
    end
  end
end
