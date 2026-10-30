defmodule CodeMySpecSpex.Story1166.Criterion2544Spex do
  @moduledoc "Story 1166, criterion 2544: slowest tests and test files in a window."

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "John sees slowest ExUnit tests, spex, and test files", criterion: 2544 do
    scenario "a 41 second sync file and its slower test are visible" do
      given_ "a completed promotion recorded per-test and per-file durations", context do
        Fixtures.landed_promotion_with_timing(context.scope,
          exunit_timings: %{
            "tests" => [
              %{
                "name" => "sync path",
                "file" => "test/cms_harness/sync_path_test.exs",
                "duration_us" => 39_000_000
              }
            ],
            "files" => [
              %{"file" => "test/cms_harness/sync_path_test.exs", "duration_us" => 41_000_000}
            ]
          },
          spex_timings: %{
            "tests" => [
              %{
                "name" => "acceptance path",
                "file" => "test/spex/acceptance_spex.exs",
                "duration_us" => 15_000_000
              }
            ],
            "files" => [%{"file" => "test/spex/acceptance_spex.exs", "duration_us" => 17_000_000}]
          }
        )

        {:ok, context}
      end

      when_ "John opens promotion timing for the last 24 hours", context do
        {:ok, view, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/promotion-timing")

        {:ok, Map.put(context, :timing_view, view)}
      end

      then_ "the slow file and its test show their separate run times", context do
        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-slowest-files-exunit'] [data-file='test/cms_harness/sync_path_test.exs'][data-duration-seconds='41.0']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-slowest-tests-exunit'] [data-file='test/cms_harness/sync_path_test.exs'][data-duration-seconds='39.0']"
               )

        assert has_element?(
                 context.timing_view,
                 "[data-test='promotion-slowest-tests-spex'] [data-file='test/spex/acceptance_spex.exs'][data-duration-seconds='15.0']"
               )

        {:ok, context}
      end
    end
  end
end
