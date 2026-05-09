defmodule CodeMySpec.Logging.LogfmtFormatterTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Logging.LogfmtFormatter

  defp event(level, msg, meta) do
    base = %{time: 1_715_268_181_123_456, level: level}
    %{level: level, msg: {:string, msg}, meta: Map.merge(base, meta)}
  end

  defp format(level, msg, meta \\ %{}, config \\ %{source: "server"}) do
    level
    |> event(msg, meta)
    |> LogfmtFormatter.format(config)
    |> IO.iodata_to_binary()
  end

  test "emits a single line ending in newline" do
    line = format(:info, "hello")
    assert String.ends_with?(line, "\n")
    assert String.split(line, "\n", trim: true) |> length() == 1
  end

  test "stamps ts, level, src, msg in order" do
    line = format(:info, "hello world")
    assert line =~ ~r/^ts=\S+ level=info src=server /
    assert line =~ ~r/msg="hello world"\n$/
  end

  test "honors source config" do
    line = format(:warning, "x", %{}, %{source: "cli"})
    assert line =~ "src=cli"
  end

  test "quotes values containing spaces, equals, quotes, newlines" do
    line = format(:info, ~s|some "weird" value=here\nline2|)
    assert line =~ ~s|msg="some \\"weird\\" value=here\\nline2"|
  end

  test "leaves bare values unquoted" do
    line = format(:info, "hi", %{request_id: "abc123"})
    assert line =~ "request_id=abc123"
    refute line =~ ~s|request_id="abc123"|
  end

  test "formats mfa as Mod.fun/N" do
    line = format(:info, "x", %{mfa: {Foo.Bar, :baz, 2}})
    assert line =~ "mfa=Foo.Bar.baz/2"
  end

  test "drops noise keys (gl, pid, file, line, domain, application)" do
    line =
      format(:info, "x", %{
        gl: self(),
        pid: self(),
        file: ~c"/tmp/foo.ex",
        line: 42,
        domain: [:elixir],
        application: :code_my_spec
      })

    refute line =~ "gl="
    refute line =~ "pid="
    refute line =~ "file="
    refute line =~ "line="
    refute line =~ "domain="
    refute line =~ "application="
  end

  test "truncates oversized values" do
    long = String.duplicate("a", 1000)
    line = format(:info, "x", %{big: long}, %{source: "server", max_value_length: 50})
    assert line =~ "...<truncated>"
    refute line =~ String.duplicate("a", 100)
  end

  test "truncates oversized messages" do
    long = String.duplicate("z", 1000)
    line = format(:info, long, %{}, %{source: "server", max_value_length: 80})
    assert line =~ "...<truncated>"
  end

  test "renders :report messages as inspect" do
    event = %{
      level: :error,
      msg: {:report, %{kind: :crash, reason: :nope}},
      meta: %{time: 1_715_268_181_000_000}
    }

    line = event |> LogfmtFormatter.format(%{source: "server"}) |> IO.iodata_to_binary()
    assert line =~ ~s|msg=|
    assert line =~ "kind: :crash"
  end

  test "renders {fmt, args} messages via :io_lib.format" do
    event = %{
      level: :info,
      msg: {~c"hello ~s", ["world"]},
      meta: %{time: 1_715_268_181_000_000}
    }

    line = event |> LogfmtFormatter.format(%{source: "server"}) |> IO.iodata_to_binary()
    assert line =~ ~s|msg="hello world"|
  end

  test "metadata keys sorted for stable output" do
    line = format(:info, "x", %{zeta: 1, alpha: 2, mu: 3})
    pos_alpha = :binary.match(line, "alpha=") |> elem(0)
    pos_mu = :binary.match(line, "mu=") |> elem(0)
    pos_zeta = :binary.match(line, "zeta=") |> elem(0)
    assert pos_alpha < pos_mu
    assert pos_mu < pos_zeta
  end

  test "never crashes — falls back to error line" do
    bad_event = %{level: :info, msg: {:bogus, :tuple, :shape}, meta: %{time: nil}}
    line = bad_event |> LogfmtFormatter.format(%{source: "server"}) |> IO.iodata_to_binary()
    assert is_binary(line)
    assert String.ends_with?(line, "\n")
  end
end
