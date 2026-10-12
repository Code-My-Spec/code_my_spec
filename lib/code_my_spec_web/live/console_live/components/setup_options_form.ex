defmodule CodeMySpecWeb.ConsoleLive.Components.SetupOptionsForm do
  @moduledoc """
  Which optional parts of setup this project has chosen — toggled on the
  console's Settings tab.

  All state (`@options`) and the one event (`toggle_setup_option`) still
  live on `ConsoleLive` — the same split `EnvironmentsForm` already draws:
  this is a plain function component, nothing here needs state or a
  lifecycle of its own.
  """

  use CodeMySpecWeb, :html

  alias CodeMySpec.ProvisioningPlan.Sequence

  attr :options, :list, required: true

  def setup_options_form(assigns) do
    assigns = assign(assigns, :choices, choices())

    ~H"""
    <div class="mt-8" data-test="setup-options-form">
      <h3 class="text-lg font-bold">Devops setup options</h3>
      <p class="opacity-70 text-sm mt-1">
        Turning one off removes its steps from the plan entirely — it will
        never show up as skipped, and setup will never run it.
      </p>

      <div class="mt-3 space-y-2">
        <label
          :for={choice <- @choices}
          data-test={"setup-option-#{choice.option}"}
          class="flex items-start gap-2"
        >
          <input
            type="checkbox"
            class="checkbox checkbox-sm mt-1"
            checked={choice.option in @options}
            phx-click="toggle_setup_option"
            phx-value-option={choice.option}
          />
          <span>
            <span class="font-medium">{choice.label}</span>
            <span class="opacity-70 text-sm block">{choice.why}</span>
          </span>
        </label>
      </div>
    </div>
    """
  end

  # One row per option, not per step — `:domain` alone covers three steps
  # (domain, dns, tls), and a project turning it off expects a single
  # control, not three that have to agree.
  defp choices do
    Sequence.all()
    |> Enum.reject(&is_nil(&1.option))
    |> Enum.uniq_by(& &1.option)
    |> Enum.map(&Map.take(&1, [:option, :label, :why]))
  end
end
