defmodule CodeMySpec.Promotion.AConflictReportedByTheHarnessIsReadTest do
  @moduledoc """
  2026-10-06: a harness's batch reported a conflict, which came back over the
  wire as `%{"commit" => …}`. The queue matched `%{commit: …}`, read no
  conflict, merged nothing, and rebuilt the same batch for hours.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Promotion.Runner

  test "a conflicted candidate comes back with atom keys" do
    copy_id = Ecto.UUID.generate()
    test = self()

    spawn_link(fn ->
      {:ok, _} = Registry.register(HarnessRegistry, copy_id, :test)
      send(test, :up)

      receive do
        {:"$gen_call", from, {:fs_request, "promotion_build_batch", _payload}} ->
          GenServer.reply(
            from,
            {:ok,
             %{
               "head" => "base",
               "merged" => [],
               "conflicted" => [%{"commit" => "c1", "files" => []}]
             }}
          )
      end
    end)

    assert_receive :up

    environment = Environment.new(:harness, "/gate", ref: %{"harness_id" => Ecto.UUID.generate()})

    assert {:ok, %{merged: [], conflicted: [%{commit: "c1", files: []}]}} =
             Runner.build_batch(environment, "/gate", "base", ["c1"], copy_id)
  end
end
