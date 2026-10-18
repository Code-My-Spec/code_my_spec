defmodule CmsHarness.Agents.Transcript do
  @moduledoc """
  A terminal Claude Code session's transcript, read as the turn events an
  agent we run reports (story 1124): what it said as `:message`, each call as
  `:tool_start` and what it returned as `:tool_end`, and the tokens each
  response spent.

  Claude Code writes one JSON object per line to
  `~/.claude/projects/<cwd>/<session>.jsonl`, and repeats a response's message
  id and usage on every line of that response, so usage is counted once per
  message id.
  """

  @type read :: %{
          events: [map()],
          usage: [map()],
          offset: non_neg_integer(),
          seen: MapSet.t(),
          tools: %{String.t() => String.t()}
        }

  @doc """
  The complete lines written to `path` since byte `offset`, as events. `seen`
  holds the message ids already counted and `tools` each call's name by id;
  pass back what this returns.
  """
  @spec read(String.t(), non_neg_integer(), MapSet.t(), map()) :: read()
  def read(path, offset, seen \\ MapSet.new(), tools \\ %{}) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, _} = :file.position(file, offset)
        chunk = IO.binread(file, :eof)
        File.close(file)
        from_chunk(chunk, offset, seen, tools)

      {:error, _} ->
        %{events: [], usage: [], offset: offset, seen: seen, tools: tools}
    end
  end

  @doc "Where reading from the end of `path` starts: its size now, or 0."
  @spec end_of(String.t() | nil) :: non_neg_integer()
  def end_of(nil), do: 0

  def end_of(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  defp from_chunk(chunk, offset, seen, tools) when is_binary(chunk) do
    # A line still being written has no newline yet; it is read next time.
    {complete, _partial} = split_complete(chunk)

    acc = %{events: [], usage: [], seen: seen, tools: tools}

    acc =
      complete
      |> Enum.map(&decode/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.reduce(acc, &entry/2)

    %{
      events: Enum.reverse(acc.events),
      usage: Enum.reverse(acc.usage),
      offset: offset + byte_size(Enum.join(Enum.map(complete, &(&1 <> "\n")))),
      seen: acc.seen,
      tools: acc.tools
    }
  end

  defp from_chunk(_eof, offset, seen, tools),
    do: %{events: [], usage: [], offset: offset, seen: seen, tools: tools}

  defp split_complete(chunk) do
    lines = String.split(chunk, "\n")
    {Enum.drop(lines, -1), List.last(lines)}
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, %{} = entry} -> entry
      _ -> nil
    end
  end

  defp entry(%{"type" => "assistant", "message" => message}, acc) do
    acc
    |> count_usage(message)
    |> blocks(message["content"], &assistant_block/2)
  end

  defp entry(%{"type" => "user", "message" => %{"content" => content}}, acc)
       when is_list(content),
       do: blocks(acc, content, &result_block/2)

  defp entry(_entry, acc), do: acc

  defp count_usage(acc, %{"id" => id, "usage" => %{} = usage} = message) do
    if MapSet.member?(acc.seen, id),
      do: acc,
      else: %{
        acc
        | seen: MapSet.put(acc.seen, id),
          usage: [Map.put(usage, "model", message["model"]) | acc.usage]
      }
  end

  defp count_usage(acc, _message), do: acc

  defp blocks(acc, content, fun) when is_list(content), do: Enum.reduce(content, acc, fun)
  defp blocks(acc, _content, _fun), do: acc

  defp assistant_block(%{"type" => "text", "text" => text}, acc) when is_binary(text),
    do: push(acc, %{event: :message, text: text})

  defp assistant_block(%{"type" => "tool_use", "id" => id, "name" => name} = block, acc) do
    acc
    |> Map.update!(:tools, &Map.put(&1, id, name))
    |> push(%{event: :tool_start, payload: %{id: id, name: name, input: block["input"] || %{}}})
  end

  defp assistant_block(_block, acc), do: acc

  defp result_block(%{"type" => "tool_result", "tool_use_id" => id} = block, acc) do
    text = result_text(block["content"])
    failed? = block["is_error"] == true

    push(acc, %{
      event: :tool_end,
      payload: %{
        id: id,
        name: Map.get(acc.tools, id, "tool"),
        result: if(failed?, do: nil, else: text),
        error: if(failed?, do: text, else: nil)
      }
    })
  end

  defp result_block(_block, acc), do: acc

  defp result_text(text) when is_binary(text), do: text

  defp result_text(parts) when is_list(parts),
    do: Enum.map_join(parts, "\n", fn part -> part["text"] || "" end)

  defp result_text(_content), do: ""

  defp push(acc, event), do: %{acc | events: [event | acc.events]}
end
