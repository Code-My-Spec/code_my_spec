defmodule CmsHarness.AScanReportsTheCopyOverlayTest do
  @moduledoc """
  After each scan the harness reports its checkout's overlay: the file
  verdicts it settled from that scan, which read model they answer, and the
  repository state only this machine can read. Sent after the manifest, so the
  server has the scan the verdicts came from. Nothing is reported to a server
  that served no records.
  """
  use ExUnit.Case, async: false

  alias CmsHarness.Sync
  alias CodeMySpec.ExecutionContexts
  alias CodeMySpec.Files.Scanner
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Requirements.Handlers

  @records %{
    "criteria_by_story" => %{"7" => [1, 2]},
    "authored" => false,
    "story_numbers" => [3],
    "context_names" => []
  }

  setup %{tmp_dir: root} do
    {:ok, _} = Registry.register(CmsHarness.Registry, {:channel, root}, nil)
    :meck.new(Scanner, [:passthrough, :no_link])
    :meck.new(ExecutionContexts, [:passthrough, :no_link])

    on_exit(fn ->
      :meck.unload(Scanner)
      :meck.unload(ExecutionContexts)
    end)

    :meck.expect(Scanner, :observe, fn _env, _model ->
      {:ok,
       [
         %{
           path: ".code_my_spec/architecture/decisions.md",
           role: :architecture,
           valid: true,
           validation_errors: nil,
           mtime: nil,
           size: 10,
           fingerprint: "f"
         }
       ]}
    end)

    :meck.expect(ExecutionContexts, :cmd, fn
      _env, "git", ["rev-parse", "HEAD"], _opts -> {"abc123\n", 0}
      _env, "git", ["rev-parse", "--abbrev-ref", "origin/HEAD"], _opts -> {"origin/main\n", 0}
      _env, "git", ["rev-list", "--count", "HEAD..origin/main"], _opts -> {"4\n", 0}
      _env, "git", ["--no-optional-locks", "status" | _], _opts -> {" M lib/a.ex\n", 0}
      _env, _command, _args, _opts -> {"", 1}
    end)

    :ok
  end

  @tag :tmp_dir
  test "the overlay follows the manifest, with its verdicts and repository state",
       %{tmp_dir: root} do
    read_model = %ReadModel{overlay_records: @records, fingerprint: "fp1"}

    :ok = Sync.run(%{root: root}, read_model)

    assert_receive {:"$gen_cast", {:observations, [_]}}
    assert_receive {:"$gen_cast", {:overlay, overlay}}

    assert %{"read_model" => "fp1", "head" => "abc123", "behind" => 4, "dirty" => true} = overlay
    assert Enum.map(overlay["verdicts"], & &1["name"]) == Handlers.copy_names()

    assert %{"default" => true} =
             Enum.find(overlay["verdicts"], &(&1["name"] == "technical_strategy"))

    assert %{"except" => [[7, false, %{"missing_criteria" => [1, 2]}]]} =
             Enum.find(overlay["verdicts"], &(&1["name"] == "bdd_specs_exist"))
  end

  @tag :tmp_dir
  test "a server that served no records gets no overlay", %{tmp_dir: root} do
    :ok = Sync.run(%{root: root}, %ReadModel{})

    assert_receive {:"$gen_cast", {:observations, [_]}}
    refute_receive {:"$gen_cast", {:overlay, _}}, 200
  end
end
