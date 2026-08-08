defmodule CodeMySpec.SpexGivensTest do
  @moduledoc """
  A `given_` has to make its precondition true, not merely state it.

  The failure this prevents is cheap to write and expensive to find. A block
  that says *"a version is deployed and serving"* and then only mounts a page
  has established nothing, so the run fails several steps later inside a
  `then_` — with a message about the thing under test rather than about the
  precondition that was never set up. On story 969 that happened four times,
  and each one cost a full ~10-minute cassette record cycle to trace back.

  ## What counts as establishing

  Driving the app: mounting a LiveView, clicking or submitting, an HTTP call,
  a `CodeMySpecSpex.Case` helper, or the `Fixtures` bridge. That list is
  deliberately generous — this catches the block that does *nothing at all*,
  which is the version that always indicates the bug.

  It cannot catch the subtler case: a block that mounts a page while claiming
  a fact about the world the mount does not create. Those need reading. This
  is the floor, not the ceiling.
  """

  use ExUnit.Case, async: true

  # `stage_` covers the family that seams a provider — stage_servers,
  # stage_containers, stage_inventory, stage_build, stage_deploy. Those are
  # `CodeMySpecSpex.Case` helpers, which the moduledoc above already counts as
  # establishing; the list simply predates them. A block saying "Sam runs two
  # servers he built himself" and calling `stage_servers/3` has made its
  # precondition true in the only way available — the provider is the thing
  # that decides, and the seam is how a criterion about *display* avoids
  # buying a machine to say so.
  @establishes ~w(
    Fixtures. live( render_click render_submit render_change element(
    post( put( patch( delete( with_provider_cassette mount_provisioning
    run_steps choose_setup_options all_setup_options own_domain built_deploy_run
    stage_servers
    existing_apex_mx paste_storage_credentials verified_sending_domains
    stuck_sending_domain unverifiable_domain app_holds_refresh_secret
    connect_providers tear_down_after Environments. File.write File.mkdir
    System.cmd assign put_session
    stage_ scripted_run built_deploy_run devops_on
  )

  # The failure message has always offered a second remedy — "if the
  # precondition is genuinely already true, say so" — and there was no way to
  # say it. `scan/0` reads the body and never the title, so retitling changed
  # nothing and the only ways out were to fake an establishing call or to add
  # the file to a baseline that forbids additions.
  #
  # This is that remedy, made real. It is deliberately wordy and has to sit in
  # the body where a reader of the given sees it, because the claim it makes is
  # the one thing this check cannot verify: that something *else* already did
  # the work. Naming what did it is the price.
  @already_established "given: already true —"

  # `given_ "title", context do ... end` — closed by an `end` at the block's
  # own indentation, which is what makes the body extractable without parsing.
  @given_block ~r/^([ ]*)given_ ("(?:[^"\\]|\\.)*")(?:, \w+)? do\n(.*?)^\1end\n/ms

  # The 54 files that predate this check, from the codebase-wide sweep in
  # issue e693c4c9. A ratchet rather than an exemption: nothing may be added,
  # and a file leaving this list must never come back. The devops epic
  # (963-974, 985) is deliberately absent — it was cleared, and this test is
  # what keeps it cleared.
  @baseline [
    "test/spex/460_bdd_specification_lifecycle/criterion_5531_missing_spec_file_is_reported_with_the_criterion_id_and_expected_path_spex.exs",
    "test/spex/460_bdd_specification_lifecycle/criterion_5536_specs_that_exist_parse_have_scenarios_with_steps_and_compile_return_valid_spex.exs",
    "test/spex/460_bdd_specification_lifecycle/criterion_5539_compilation_failure_produces_a_diagnostic_listing_each_errors_file_and_line_spex.exs",
    "test/spex/460_bdd_specification_lifecycle/criterion_5556_every_component_types_prompt_scaffold_opens_with_use_app_spex_case_as_the_only_test_case_use_spex.exs",
    "test/spex/460_bdd_specification_lifecycle/criterion_5557_spec_written_with_conncase_instead_of_spex_case_fails_to_compile_on_undefined_spex_macro_spex.exs",
    "test/spex/602_oauth_registration_logs_the_user_in_via_the_callback/criterion_5493_first_google_signup_creates_a_user_with_confirmed_at_set_spex.exs",
    "test/spex/602_oauth_registration_logs_the_user_in_via_the_callback/criterion_5495_second_google_sign-in_returns_the_same_user_with_no_duplicate_records_spex.exs",
    "test/spex/602_oauth_registration_logs_the_user_in_via_the_callback/criterion_5496_same_email_from_a_different_oauth_provider_links_to_the_existing_user_instead_of_creating_a_new_one_spex.exs",
    "test/spex/603_onboarding_lives_at_app_and_reveals_the_next_setup_step/criterion_5502_routes_redirect_to_app_when_user_lacks_account_or_project_spex.exs",
    "test/spex/607_new_user_reaches_a_working_app_state_without_seeing_the_account_picker/criterion_5521_zero_account_user_redirected_to_app_from_guarded_route_spex.exs",
    "test/spex/607_new_user_reaches_a_working_app_state_without_seeing_the_account_picker/criterion_5523_single_account_user_reaches_projects_without_picker_spex.exs",
    "test/spex/607_new_user_reaches_a_working_app_state_without_seeing_the_account_picker/criterion_5524_multi_account_user_auto_picks_first_bypassing_picker_spex.exs",
    "test/spex/607_new_user_reaches_a_working_app_state_without_seeing_the_account_picker/criterion_5527_direct_visit_renders_picker_spex.exs",
    "test/spex/677_spex_boundary_readiness_gate/criterion_5751_empty_fixtures_bridge_file_still_passes_the_checker_spex.exs",
    "test/spex/686_ai_assisted_story_management/criterion_5912_agent_creates_and_applies_a_tag_spex.exs",
    "test/spex/688_always_fresh_project_documentation_search/criterion_5973_the_agents_mcp_tool_list_does_not_expose_embed_docs_spex.exs",
    "test/spex/689_always_fresh_hex_documentation_search/criterion_5981_the_agents_mcp_tool_list_does_not_expose_embed_hexdocs_spex.exs",
    "test/spex/698_dashboard_install_funnel_with_live_cli_status/criterion_6040_pill_counts_multiple_live_cli_sessions_spex.exs",
    "test/spex/698_dashboard_install_funnel_with_live_cli_status/criterion_6046_previously_connected_user_sees_the_onboarding_component_minimized_spex.exs",
    "test/spex/700_onboarding_workflow_guides_me_from_signup_to_the_local_application/criterion_6054_user_with_all_server_side_setup_done_has_application_as_the_active_step_spex.exs",
    "test/spex/700_onboarding_workflow_guides_me_from_signup_to_the_local_application/criterion_6058_active_application_step_opens_the_local_workspace_in_a_new_tab_spex.exs",
    "test/spex/70_architecture_design/criterion_5289_architect_links_every_unsatisfied_story_to_at_least_one_component_spex.exs",
    "test/spex/70_architecture_design/criterion_5290_architect_leaves_an_unsatisfied_story_without_any_component_link_spex.exs",
    "test/spex/70_architecture_design/criterion_5313_architect_declares_a_dependency_on_a_component_that_does_not_exist_spex.exs",
    "test/spex/70_architecture_design/criterion_5657_architect_classifies_an_orphaned_framework_module_by_adding_its_path_to_infrastructure_paths_spex.exs",
    "test/spex/713_content_generator-output_rendering_surface_in_deployed_client_apps/criterion_6277_valid_trigger_with_matching_deploy_key_kicks_off_the_sync_spex.exs",
    "test/spex/713_content_generator-output_rendering_surface_in_deployed_client_apps/criterion_6278_well-formed_manifest_parses_into_the_expected_fields_spex.exs",
    "test/spex/713_content_generator-output_rendering_surface_in_deployed_client_apps/criterion_6279_blob_whose_hash_matches_the_manifest_passes_verification_spex.exs",
    "test/spex/713_content_generator-output_rendering_surface_in_deployed_client_apps/criterion_6280_new_manifest_replaces_local_content_atomically_spex.exs",
    "test/spex/713_content_generator-output_rendering_surface_in_deployed_client_apps/criterion_6281_future-publish_and_expired_slugs_return_404_without_re-pulling_spex.exs",
    "test/spex/713_content_generator-output_rendering_surface_in_deployed_client_apps/criterion_6282_tag-filtered_index_lists_only_currently_in-window_slugs_spex.exs",
    "test/spex/715_architect_surveys_the_project/criterion_6309_unknown_requirement_component_story_reference_returns_a_not_found_error_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6440_agent_submits_a_completed_qa_pass_with_one_tool_call_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6441_submit_with_all_required_fields_returns_an_attempt_id_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6442_submit_without_status_is_rejected_at_the_tool_boundary_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6447_structured_scenarios_are_queryable_individually_after_submit_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6448_submit_with_scenarios_as_a_single_string_is_rejected_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6449_status_pass_satisfies_qa_complete_spex.exs",
    "test/spex/726_agent_submits_qa_outcomes_through_validated_tool_calls/criterion_6487_submit_with_fail_or_partial_status_and_empty_issue_ids_is_rejected_at_the_tool_boundary_spex.exs",
    "test/spex/727_engineer_trusts_qa_pass_claims_as_audit-grade_events/criterion_6452_qa_submission_creates_a_row_that_persists_across_server_restarts_spex.exs",
    "test/spex/727_engineer_trusts_qa_pass_claims_as_audit-grade_events/criterion_6453_db_pass_attempt_satisfies_qa_complete_regardless_of_disk_state_spex.exs",
    "test/spex/811_user_sees_the_agents_task_queue_at_a_glance/criterion_6492_head_of_displayed_queue_equals_get_next_requirements_return_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6509_oauth_existing_via_provider_identity_is_silent_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6510_oauth_existing_via_email_auto_link_is_silent_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6512_first_cms_connect_dispatches_first_cli_connect_once_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6513_subsequent_cms_connects_do_not_re_fire_first_cli_connect_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6534_root_layout_loads_gtag_js_async_with_the_ga4_measurement_id_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6536_register_and_onboarding_mounts_fire_their_gtag_behavior_events_spex.exs",
    "test/spex/812_analytics_tracking_and_traffic_filtering/criterion_6539_server_mp_conversions_carry_the_gtag_session_id_from_the_ga_session_cookie_spex.exs",
    "test/spex/815_sam_sends_and_receives_messages_with_his_users/criterion_6576_user_sees_only_their_own_conversation_spex.exs",
    "test/spex/815_sam_sends_and_receives_messages_with_his_users/criterion_6577_cross-user_access_is_denied_spex.exs",
    "test/spex/817_manage_google_ads_through_the_agent/criterion_6602_an_unconnected_account_prompts_the_user_to_connect_google_spex.exs",
    "test/spex/983_spec_failures_block_only_stories_whose_specs_have_gone_green/criterion_8161_a_later_edit_stales_the_spex_run_without_un-readying_the_story_spex.exs",
    "test/spex/983_spec_failures_block_only_stories_whose_specs_have_gone_green/criterion_8168_reaching_specs-ready_releases_qa_on_the_story_spex.exs"
  ]

  test "no new given_ block states a precondition without establishing it" do
    offenders = scan()
    new_offenders = Enum.reject(offenders, fn {path, _line, _title} -> path in @baseline end)

    assert new_offenders == [],
           """
           These given_ blocks state a precondition and do nothing to make it true:

           #{format(new_offenders)}

           A given_ should drive the app — mount the view, click, submit, call a
           Case helper, or go through the Fixtures bridge.

           If the precondition is genuinely already true, say so in the body and
           name what made it true:

               # given: already true — `setup :setup_active_project` creates it.
           """
  end

  test "the baseline shrinks and never grows" do
    still_offending = scan() |> Enum.map(fn {path, _, _} -> path end) |> MapSet.new()
    stale = Enum.reject(@baseline, &MapSet.member?(still_offending, &1))

    assert stale == [],
           """
           These files were fixed but are still listed in @baseline:

           #{Enum.map_join(stale, "\n", &("  " <> &1))}

           Remove them. A baseline that keeps fixed files lets them regress
           silently, which is the one thing it exists to prevent.
           """
  end

  defp scan do
    for path <- Path.wildcard("test/spex/**/*_spex.exs"),
        source = File.read!(path),
        [whole, indent, title, body] <- Regex.scan(@given_block, source),
        not String.contains?(body, @establishes),
        not String.contains?(body, @already_established) do
      _ = whole
      offset = source |> String.split(indent <> "given_ " <> title) |> hd()
      {path, length(String.split(offset, "\n")), String.trim(title, ~s("))}
    end
  end

  defp format(offenders) do
    Enum.map_join(offenders, "\n", fn {path, line, title} -> "  #{path}:#{line}  #{title}" end)
  end
end
