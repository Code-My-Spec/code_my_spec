defmodule CmsHarnessTest.AnalysisResults do
  @moduledoc """
  Waiting on the real analyzer path: a harness connected, and a result for a
  specific run.

  Extracted because `analysis_path_test.exs` wrote both once and story 839's
  criteria need them eight more times — a helper copied eight times is the
  same parsing bug fixed seven times and missed once that `WorkingCopyHelpers`
  already learned this lesson about.

  Both read off the real wire: `ChannelClient.connected?/1` is the harness's
  own liveness check, and a result arrives as `{:analysis_result, project_id,
  payload}` because `CmsHarnessTest.FakeServer.listen/1` was told to notify
  this process — nothing here is a poll of internal state standing in for the
  real one.
  """

  import ExUnit.Assertions

  alias CmsHarness.Project.ChannelClient

  @doc "Block until the harness at `root` has joined the fake server."
  @spec await_connected(String.t(), pos_integer()) :: true
  def await_connected(root, attempts \\ 200) do
    result =
      Enum.reduce_while(1..attempts, false, fn _, _ ->
        connected_step(ChannelClient.connected?(root))
      end)

    assert result, "#{root}'s harness never connected to the fake server"
  end

  defp connected_step(true), do: {:halt, true}

  defp connected_step(false) do
    Process.sleep(10)
    {:cont, false}
  end

  @doc """
  Block until `run_id`'s result arrives, draining unrelated ones so they
  cannot be mistaken for the answer.
  """
  @spec await_result(integer(), timeout()) :: map()
  def await_result(run_id, timeout \\ 5_000) do
    receive do
      {:analysis_result, _project_id, %{"run_id" => ^run_id} = payload} -> payload
      {:analysis_result, _project_id, _other} -> await_result(run_id, timeout)
    after
      timeout -> flunk("no analysis_result for run #{run_id} within #{timeout}ms")
    end
  end

  @doc """
  Assert that no result for `run_id` arrives within `timeout` — the run is
  still genuinely in flight (queued, waiting for a slot, or executing), not
  finished.
  """
  @spec refute_result_yet(integer(), timeout()) :: :ok
  def refute_result_yet(run_id, timeout \\ 200) do
    receive do
      {:analysis_result, _project_id, %{"run_id" => ^run_id} = payload} ->
        flunk(
          "run #{run_id} already has a result, expected it still in flight: #{inspect(payload)}"
        )

      {:analysis_result, _project_id, _other} ->
        refute_result_yet(run_id, timeout)
    after
      timeout -> :ok
    end
  end

  @doc """
  Assert two `analysis_result` payloads answer with the same real result —
  run_id aside — without requiring their raw `output` text to match
  byte-for-byte.

  Two independent, genuinely clean runs of the same real tool legitimately
  print different things: a cold `mix compile` announces what it compiled,
  a warm one with nothing left to redo prints nothing at all, even though
  neither run found a single diagnostic. Requiring literal `output` equality
  here would assert the tool is deterministic, not that what came back is a
  real result rather than the old `{:superseded, "already queued"}` shape
  this guards against — so each payload's own `output` is checked for being
  real captured text instead of compared to the other's.
  """
  @spec assert_same_real_result(map(), map()) :: :ok
  def assert_same_real_result(a, b) do
    assert is_binary(get_in(a, ["result", "output"])),
           "expected a real captured output, got: #{inspect(a)}"

    assert is_binary(get_in(b, ["result", "output"])),
           "expected a real captured output, got: #{inspect(b)}"

    strip = fn payload ->
      payload
      |> Map.delete("run_id")
      |> Map.update!("result", &Map.delete(&1, "output"))
    end

    assert strip.(a) == strip.(b),
           "expected the same real result (run_id and raw tool output " <>
             "aside), never a synthetic status carrying no data. Got: " <>
             "#{inspect(a)} and #{inspect(b)}"

    :ok
  end
end
