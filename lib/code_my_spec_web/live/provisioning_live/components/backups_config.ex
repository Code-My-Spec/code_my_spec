defmodule CodeMySpecWeb.ProvisioningLive.Components.BackupsConfig do
  @moduledoc """
  The backups step's own markup, factored out of `step_card`'s branches.

  A dump is a file until something has read it back. The step restores into
  a scratch database and counts the rows; that count is the whole claim, so
  it is on the page rather than folded into "done" (criterion 8054).
  Retention is enforced by the bucket's own lifecycle rule, not by anything
  this app runs on a schedule — so a dump expires whether or not setup ever
  runs again (criterion 8016).
  """

  use CodeMySpecWeb, :html

  attr :step, :map, required: true

  def backups_config(assigns) do
    ~H"""
    <span
      :for={pr <- Enum.filter(@step.resources, &(&1.kind == "restore_proof"))}
      data-test="backup-restore-proof"
      data-target={pr.location}
      data-rows={pr.identifier |> String.split(" ") |> hd() |> String.replace_prefix("rows=", "")}
      data-completed-at={
        pr.identifier
        |> String.split(" ")
        |> List.last()
        |> String.replace_prefix("proven_at=", "")
      }
      data-content-verified={
        pr.identifier
        |> String.split(" ")
        |> hd()
        |> String.replace_prefix("rows=", "")
        |> then(&(&1 != "0"))
        |> to_string()
      }
      class="mt-1 block text-xs font-mono opacity-70"
    >
      restored into {pr.location}: {pr.identifier}
    </span>

    <span
      :for={r <- Enum.filter(@step.resources, &(&1.kind == "retention"))}
      data-test="backup-retention"
      data-days={r.location |> String.replace_suffix(" days", "")}
      data-enforced-by="bucket_lifecycle"
      class="mt-1 block text-xs font-mono opacity-70"
    >
      dumps expire after {r.location}
    </span>
    """
  end
end
