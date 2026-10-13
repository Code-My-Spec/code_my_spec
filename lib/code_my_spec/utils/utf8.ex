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

  @doc """
  Scrubs `binary` to valid, printable UTF-8 without dropping it.

  For content that may be invalid *throughout* rather than only at a
  truncation boundary — a stored turn whose raw bytes were never valid UTF-8
  to begin with, so `valid_prefix/2`'s boundary trim does not apply. Null
  bytes and other non-printable control characters (besides `\\n`, `\\t`,
  `\\r`) are stripped; any remaining invalid sequences are reinterpreted as
  Latin-1 and re-encoded, which keeps every byte as *some* character rather
  than discarding the content a strict decode would reject (issue 5df56711:
  encoding an unscrubbed turn for an MCP response crashed the whole session).
  """
  @spec scrub(binary()) :: binary()
  def scrub(binary) when is_binary(binary) do
    binary
    |> String.replace(<<0>>, "")
    |> String.replace(~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/, "")
    |> ensure_printable()
  end

  defp ensure_printable(text) do
    if String.valid?(text) do
      text
    else
      case :unicode.characters_to_binary(text, :latin1, :utf8) do
        binary when is_binary(binary) -> binary
        _ -> ""
      end
    end
  end
end
