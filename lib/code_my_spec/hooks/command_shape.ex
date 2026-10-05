defmodule CodeMySpec.Hooks.CommandShape do
  @moduledoc """
  Where the `mix test` / `mix spex` is in a shell command, so only that part is
  routed.

  An agent's test command is almost never bare: on 2026-10-03, 0.2% of 6,831
  were. It is `MIX_ENV=test mix test x 2>&1 | tail -20`, or `cd X && …`, or
  followed by `; echo`. Routing used to require the whole command to be the
  test, so it routed almost nothing.

  This splits a command into segments on `&&`, `||`, `;`, `|` and newlines,
  outside quotes, and finds the segments that run mix test or spex. Each is
  swapped for what `route/2`'s function returns, with its redirects kept, so
  `mix test x 2>&1 | tail -20` becomes `<run x> 2>&1 | tail -20`. Everything
  else in the command stays as written.

  A command it cannot split with confidence passes through unrouted: a heredoc,
  a command substitution, a backgrounding `&`, unbalanced quotes. So does a
  test segment with an environment prefix other than `MIX_ENV=test`, which the
  run would not carry.
  """

  @type mix :: %{
          task: String.t(),
          source: String.t(),
          args: [String.t()],
          cd: String.t() | :unknown | nil
        }

  @type class ::
          :not_test | :simple | :piped | :redirected | :cd | :compound | :env | :unparseable

  @doc """
  Swap each test segment of `command` for `replace.(mix)`.

  `{:routed, command, classes, mixes}` when at least one segment was swapped,
  `{:pass, classes}` otherwise. `replace` answers `{:ok, replacement}`, or
  `:pass` for a segment it will not route. `classes` describe the command's
  shape, for the log.
  """
  @spec route(String.t(), (mix() -> {:ok, String.t()} | :pass)) ::
          {:routed, String.t(), [class()], [mix()]} | {:pass, [class()]}
  def route(command, replace) when is_binary(command) do
    case segments(command) do
      :unparseable ->
        {:pass, [if(test?(command), do: :unparseable, else: :not_test)]}

      {:ok, segments} ->
        segments |> with_mix() |> swap(command, replace)
    end
  end

  @doc "Whether `command` names a mix test or spex run anywhere, parseable or not."
  @spec test?(String.t()) :: boolean()
  def test?(command), do: Regex.match?(~r/\bmix\s+(test|spex)\b/, command)

  # -- Segments ----------------------------------------------------------------

  # `[{text, start, op_after}]`, offsets into `command`.
  defp segments(command) do
    if Regex.match?(~r/<<|\$\(|`/, command) do
      :unparseable
    else
      case scan(String.to_charlist(command), 0, nil, []) do
        :unparseable -> :unparseable
        ops -> {:ok, cut(command, Enum.reverse(ops))}
      end
    end
  end

  # `{offset, op}` for each operator outside quotes. Offsets are bytes; a
  # multibyte character only ever appears inside a word, never in an operator,
  # so its width is counted from its own encoding.
  defp scan([], _i, nil, ops), do: ops
  defp scan([], _i, _quote, _ops), do: :unparseable

  defp scan([?\\, c | rest], i, quote, ops) when quote in [nil, ?"],
    do: scan(rest, i + 1 + width(c), quote, ops)

  defp scan([q | rest], i, nil, ops) when q in [?', ?"], do: scan(rest, i + 1, q, ops)
  defp scan([q | rest], i, q, ops), do: scan(rest, i + 1, nil, ops)
  defp scan([c | rest], i, quote, ops) when quote != nil, do: scan(rest, i + width(c), quote, ops)
  defp scan([?&, ?& | rest], i, nil, ops), do: scan(rest, i + 2, nil, [{i, "&&"} | ops])
  defp scan([?|, ?| | rest], i, nil, ops), do: scan(rest, i + 2, nil, [{i, "||"} | ops])
  # `2>&1`, `>&2`, `&>`: redirects, not operators.
  defp scan([?>, ?& | rest], i, nil, ops), do: scan(rest, i + 2, nil, ops)
  defp scan([?&, ?> | rest], i, nil, ops), do: scan(rest, i + 2, nil, ops)
  defp scan([?& | _rest], _i, nil, _ops), do: :unparseable

  defp scan([c | rest], i, nil, ops) when c in [?;, ?|, ?\n],
    do: scan(rest, i + 1, nil, [{i, <<c>>} | ops])

  defp scan([c | rest], i, nil, ops), do: scan(rest, i + width(c), nil, ops)

  defp width(c), do: byte_size(<<c::utf8>>)

  defp cut(command, ops) do
    {segments, last} =
      Enum.map_reduce(ops, 0, fn {at, op}, from ->
        {{binary_part(command, from, at - from), from, op}, at + byte_size(op)}
      end)

    segments ++ [{binary_part(command, last, byte_size(command) - last), last, nil}]
  end

  # -- Test segments -----------------------------------------------------------

  # Each segment with its parsed test run, or nil, carrying the directory every
  # `cd` before it moved to, whatever operator joined them: `cd X && S=1; mix
  # test` runs in X. A move it cannot follow (`cd $DIR`, `cd -`, `pushd`) is
  # `:unknown`, and a test after it is not routed.
  defp with_mix(segments) do
    {paired, _cd} =
      Enum.map_reduce(segments, nil, fn {text, start, op}, cd ->
        {{text, start, op, mix(text, cd)}, next_cd(text, cd)}
      end)

    paired
  end

  defp next_cd(text, cd) do
    case tokens(text) do
      [{"cd", _, _}, {dir, _, _}] -> moved(cd, unquote_word(dir))
      [{word, _, _} | _] when word in ["cd", "pushd", "popd"] -> :unknown
      _ -> cd
    end
  end

  defp moved(_cd, dir) when dir in ["-", ""], do: :unknown
  defp moved(:unknown, _dir), do: :unknown

  defp moved(cd, dir) do
    cond do
      String.contains?(dir, ["$", "`"]) -> :unknown
      Path.type(dir) == :absolute or cd == nil -> dir
      true -> Path.join(cd, dir)
    end
  end

  # `{:ok, mix, from, redirects}`: where the replacement starts in the segment
  # and the redirects to keep after it. `:env` for a test segment whose env
  # prefix the run would drop, `:unparseable` for args that cannot be split.
  defp mix(text, cd) do
    {env, rest} = text |> tokens() |> Enum.split_while(&env_assignment?/1)

    case rest do
      [{"mix", from, _}, {task, _, _} | args] when task in ["test", "spex"] ->
        from = env |> List.first({nil, from, nil}) |> elem(1)

        if Enum.all?(env, &(elem(&1, 0) == "MIX_ENV=test")),
          do: test_segment(task, args, from, cd),
          else: :env

      _ ->
        nil
    end
  end

  defp env_assignment?({raw, _, _}), do: Regex.match?(~r/^[A-Za-z_]\w*=/, raw)

  defp test_segment(task, args, from, cd) do
    {kept, redirects} = split_redirects(args, [], [])

    case kept |> Enum.map_join(" ", &elem(&1, 0)) |> split_args() do
      {:ok, parsed} ->
        {:ok, %{task: task, source: source(task), args: parsed, cd: cd}, from,
         Enum.map(redirects, &elem(&1, 0))}

      :error ->
        :unparseable
    end
  end

  # `>`, `2>`, `>>`, `&>`, `<` alone take the next word as their target;
  # `2>&1`, `>out.txt`, `2>/dev/null` carry theirs.
  @bare_redirects [">", ">>", "<", "&>", "1>", "2>", "1>>", "2>>"]

  defp split_redirects([], kept, redirects), do: {Enum.reverse(kept), Enum.reverse(redirects)}

  defp split_redirects([{raw, _, _} = token, target | rest], kept, redirects)
       when raw in @bare_redirects,
       do: split_redirects(rest, kept, [target, token | redirects])

  defp split_redirects([{raw, _, _} = token | rest], kept, redirects) do
    if Regex.match?(~r/^[12&]?(>>|>|<)/, raw),
      do: split_redirects(rest, kept, [token | redirects]),
      else: split_redirects(rest, [token | kept], redirects)
  end

  defp split_args(""), do: {:ok, []}

  defp split_args(raw) do
    {:ok, OptionParser.split(raw)}
  rescue
    _ -> :error
  end

  defp source("test"), do: "exunit"
  defp source("spex"), do: "spex"

  # Whitespace-separated words, quotes kept whole, with their byte offsets.
  defp tokens(text) do
    ~r/(?:[^\s'"\\]|\\.|'[^']*'|"(?:[^"\\]|\\.)*")+/
    |> Regex.scan(text, return: :index)
    |> Enum.map(fn [{at, len}] -> {binary_part(text, at, len), at, at + len} end)
  end

  defp unquote_word(word) do
    case OptionParser.split(word) do
      [dir] -> dir
      _ -> word
    end
  rescue
    _ -> word
  end

  # -- Swap --------------------------------------------------------------------

  # Each routed segment is replaced from its env prefix to its end, without
  # trailing whitespace; the redirects in that span follow the replacement.
  defp swap(segments, command, replace) do
    {edits, mixes} =
      Enum.flat_map_reduce(segments, [], fn
        {text, start, _op, {:ok, run, from, redirects}}, mixes ->
          case replace.(run) do
            {:ok, replacement} ->
              to = start + byte_size(String.trim_trailing(text))
              {[{start + from, to, Enum.join([replacement | redirects], " ")}], [run | mixes]}

            :pass ->
              {[], mixes}
          end

        _segment, mixes ->
          {[], mixes}
      end)

    case edits do
      [] -> {:pass, classes(segments)}
      edits -> {:routed, apply_edits(command, edits), classes(segments), Enum.reverse(mixes)}
    end
  end

  defp apply_edits(command, edits) do
    edits
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.reduce(command, fn {from, to, replacement}, acc ->
      binary_part(acc, 0, from) <> replacement <> binary_part(acc, to, byte_size(acc) - to)
    end)
  end

  defp classes(segments) do
    mixes = for {_, _, _, mix} <- segments, mix != nil, do: mix

    cond do
      mixes == [] -> [:not_test]
      :env in mixes -> [:env]
      :unparseable in mixes -> [:unparseable]
      true -> shape(segments)
    end
  end

  defp shape(segments) do
    ops = for {_, _, op, _} <- segments, op != nil, do: op

    [
      cd: Enum.any?(segments, &match?({_, _, _, {:ok, %{cd: cd}, _, _}} when cd != nil, &1)),
      piped: "|" in ops,
      redirected: Enum.any?(segments, &match?({_, _, _, {:ok, _, _, [_ | _]}}, &1)),
      compound: Enum.any?(ops, &(&1 in ["&&", "||", ";", "\n"]))
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
    |> case do
      [] -> [:simple]
      classes -> classes
    end
  end
end
