defmodule CmsHarness.AHeldScanAnswersAsTheWholeScanTest do
  @moduledoc """
  Between scans the harness holds only what the overlay reads of the last one,
  packed: a whole scan is about 6 MB a checkout, most of it what code files'
  validation recorded. Recomputed from what is held, the overlay is the one
  the whole scan gives.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Sync
  alias CodeMySpec.Files.Scanner.ReadModel
  alias CodeMySpec.Paths
  alias CodeMySpec.Requirements.CopyOverlay

  @evidence %{"modules" => ["MyApp.Billing"], "references" => [%{"target" => "Ecto"}]}

  @scan [
    %{
      path: "lib/my_app/billing.ex",
      role: :implementation,
      valid: true,
      size: 10,
      mtime: nil,
      fingerprint: "a",
      validation_errors: %{
        "data" => %{"module_name" => "MyApp.Billing", "dependency_evidence" => @evidence}
      }
    },
    %{
      path: "mix.exs",
      role: :mix_exs,
      valid: true,
      size: 10,
      mtime: nil,
      fingerprint: "b",
      validation_errors: %{"data" => %{"app_name" => "my_app"}}
    },
    %{
      path: "test/spex/7_billing/criterion_1_spex.exs",
      role: :bdd_spec,
      valid: true,
      size: 10,
      mtime: nil,
      fingerprint: "c",
      validation_errors: %{"data" => %{"criterion" => 1, "scenarios" => ["a", "b"]}}
    },
    %{
      path: Paths.decisions_index(),
      role: :architecture,
      valid: false,
      size: 10,
      mtime: nil,
      fingerprint: "d",
      validation_errors: %{"errors" => %{"sections" => ["missing Context"]}}
    },
    %{
      path: Paths.proposal_path(),
      role: :architecture,
      valid: true,
      size: 10,
      mtime: nil,
      fingerprint: "e",
      validation_errors: %{"data" => %{"story_numbers" => [7, 99], "context_names" => []}}
    }
  ]

  @read_model %ReadModel{
    component_by_module: %{"MyApp.Billing" => "c1"},
    component_by_id: %{"c1" => %{module_name: "MyApp.Billing", type: "context"}},
    overlay_records: %{
      "criteria_by_story" => %{"7" => [1, 2]},
      "authored" => false,
      "story_numbers" => [7],
      "context_names" => ["MyApp.Billing"]
    }
  }

  test "the overlay from the held scan is the overlay from the whole scan" do
    held = :erlang.binary_to_term(Sync.retained(@scan))

    assert CopyOverlay.verdicts(held, @read_model) == CopyOverlay.verdicts(@scan, @read_model)
  end

  test "what is held leaves out the code files' recorded evidence" do
    assert byte_size(Sync.retained(@scan)) <
             byte_size(:erlang.term_to_binary(@scan, [:compressed]))

    held = :erlang.binary_to_term(Sync.retained(@scan))
    refute inspect(held) =~ "dependency_evidence"
  end
end
