defmodule CmsHarness.Agents.Spill do
  @moduledoc """
  A long tool result written to a file, with a notice in its place.

  Cutting a result keeps part of it and loses the rest: a coder's `cat a b c`
  lost `c` and was told only that something was truncated. Spilled, all of it
  is kept outside the checkout, and the agent sees where, with the beginning
  and the end (where errors and summaries usually are).

  Done by the tools themselves (`Tools.Bash`, `Tools.Read`), which hold the
  whole output: Alloy truncates a result to the tool's `max_result_chars`
  before any middleware sees it, so a spill there would save the cut copy.
  The directory rides the tool context as `:spill_dir`.
  """

  @threshold 10_000
  @preview_chars 2_000
  @tail_chars 1_000

  @doc """
  `text` as the agent should receive it: unchanged when short or when no
  directory is configured, otherwise the notice for a file holding all of it.
  """
  @spec shape(String.t(), map(), String.t()) :: String.t()
  def shape(text, context, tool_name) when is_binary(text) do
    with dir when is_binary(dir) <- Map.get(context, :spill_dir),
         length when length > @threshold <- String.length(text),
         {:ok, path} <- write(dir, tool_name, text) do
      notice(text, length, path)
    else
      _ -> text
    end
  end

  def shape(other, _context, _tool_name), do: other

  defp write(dir, tool_name, text) do
    path = Path.join(dir, "#{tool_name}-#{System.unique_integer([:positive, :monotonic])}.txt")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, text) do
      {:ok, path}
    end
  end

  defp notice(text, length, path) do
    omitted = length - @preview_chars - @tail_chars

    "Output too large (#{length} chars). Full output saved to:\n#{path}\n" <>
      "Read that file in parts (sed -n, grep) for anything not shown here.\n\n" <>
      "First #{@preview_chars} chars:\n" <>
      String.slice(text, 0, @preview_chars) <>
      "\n\n[... #{omitted} chars omitted ...]\n\nLast #{@tail_chars} chars:\n" <>
      String.slice(text, -@tail_chars, @tail_chars)
  end
end
