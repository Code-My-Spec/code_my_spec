defmodule CodeMySpec.Logging.LogfmtFormatter do
  @moduledoc """
  `:logger` formatter that emits one logfmt line per event.

      ts=2026-05-09T14:23:01.123Z level=info src=server req=abc123 mfa=Foo.Bar.baz/2 msg="..."

  Optimized for LLM consumption: single line, dense `key=value` pairs,
  greppable, low token cost. Long values are truncated so a single bad
  log line cannot blow the reader's context window.

  ## Usage

      :logger.add_handler(:codemyspec_file, :logger_std_h, %{
        config: %{type: {:file, ~c"~/.codemyspec/server.log"}},
        formatter: {CodeMySpec.Logging.LogfmtFormatter, %{source: "server"}}
      })

  ## Config

    * `:source` — `"server"` or `"cli"`. Stamped on every line as `src=`.
      Defaults to `"server"`.
    * `:max_value_length` — bytes. Per-value truncation threshold.
      Defaults to `500`.
  """

  @default_max_value_length 500
  @truncation_marker "...<truncated>"

  # Keys handled explicitly or that add no signal at LLM-read time.
  @drop_keys ~w(gl ansi_color erl_level report_cb pid time level msg
                registered_name initial_call file line domain
                application)a

  @spec format(:logger.log_event(), map()) :: IO.chardata()
  def format(%{level: level, msg: msg, meta: meta}, config) do
    config = normalize_config(config)
    source = Map.get(config, :source, "server")
    max_len = Map.get(config, :max_value_length, @default_max_value_length)

    head = [
      {"ts", format_time(meta[:time])},
      {"level", Atom.to_string(level)},
      {"src", source}
    ]

    mfa_pair =
      case meta[:mfa] do
        nil -> []
        mfa -> [{"mfa", format_mfa(mfa)}]
      end

    user_pairs =
      meta
      |> Map.drop(@drop_keys)
      |> Enum.sort_by(fn {k, _} -> to_string(k) end)
      |> Enum.map(fn {k, v} -> {to_string(k), format_value(v, max_len)} end)

    msg_pair = [{"msg", format_msg(msg, max_len)}]

    pairs = head ++ mfa_pair ++ user_pairs ++ msg_pair

    [encode_pairs(pairs), ?\n]
  rescue
    err ->
      [
        "ts=",
        format_time(System.system_time(:microsecond)),
        " level=error src=logfmt_formatter msg=\"formatter crashed: ",
        err |> Exception.message() |> escape_value(),
        "\"\n"
      ]
  end

  defp normalize_config(config) when is_map(config), do: config
  defp normalize_config(config) when is_list(config), do: Map.new(config)
  defp normalize_config(_), do: %{}

  defp encode_pairs(pairs) do
    pairs
    |> Enum.map(fn {k, v} -> [k, ?=, encode_value(v)] end)
    |> Enum.intersperse(?\s)
  end

  defp encode_value(v) when is_binary(v) do
    if needs_quotes?(v), do: [?", escape_value(v), ?"], else: v
  end

  defp encode_value(v), do: encode_value(to_string(v))

  defp needs_quotes?(""), do: true

  defp needs_quotes?(v) do
    String.contains?(v, [" ", "\t", "\"", "=", "\n"])
  end

  defp escape_value(v) do
    v
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
    |> String.replace("\r", "\\r")
    |> String.replace("\t", "\\t")
  end

  defp format_value(v, max_len) do
    v |> value_to_string() |> truncate(max_len)
  end

  defp value_to_string(v) when is_binary(v), do: v
  defp value_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp value_to_string(v) when is_number(v), do: to_string(v)

  defp value_to_string(v) when is_list(v) do
    if List.ascii_printable?(v), do: List.to_string(v), else: inspect(v)
  end

  defp value_to_string(v), do: inspect(v)

  defp truncate(str, max_len) when byte_size(str) <= max_len, do: str

  defp truncate(str, max_len) do
    keep = max(max_len - byte_size(@truncation_marker), 0)
    binary_part(str, 0, keep) <> @truncation_marker
  end

  defp format_msg({:string, iodata}, max_len) do
    iodata |> IO.iodata_to_binary() |> truncate(max_len)
  end

  defp format_msg({:report, report}, max_len) when is_map(report) or is_list(report) do
    report |> inspect() |> truncate(max_len)
  end

  defp format_msg({:report, report, _fun}, max_len) do
    report |> inspect() |> truncate(max_len)
  end

  defp format_msg({fmt, args}, max_len) when (is_list(fmt) or is_binary(fmt)) and is_list(args) do
    try do
      fmt |> :io_lib.format(args) |> IO.iodata_to_binary() |> truncate(max_len)
    rescue
      _ -> {fmt, args} |> inspect() |> truncate(max_len)
    end
  end

  defp format_msg(other, max_len), do: other |> inspect() |> truncate(max_len)

  defp format_time(nil), do: format_time(System.system_time(:microsecond))

  defp format_time(microseconds) when is_integer(microseconds) do
    microseconds
    |> DateTime.from_unix!(:microsecond)
    |> DateTime.to_iso8601()
  end

  defp format_mfa({mod, fun, arity}) when is_atom(mod) and is_atom(fun) and is_integer(arity) do
    "#{inspect(mod)}.#{fun}/#{arity}"
  end

  defp format_mfa(other), do: inspect(other)
end
