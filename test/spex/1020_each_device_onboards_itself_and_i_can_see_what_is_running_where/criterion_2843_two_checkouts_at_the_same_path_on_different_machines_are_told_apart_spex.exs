defmodule CodeMySpecSpex.Story1020.Criterion2843Spex do
  @moduledoc """
  Story 1020 — Each device onboards itself and I can see what is running where.
  Criterion 2843 — Two checkouts at the same path on different machines are told
  apart.

  Rule: A working copy says which machine it is on.

  This is the case that made identity server-issued in the first place. Two
  containers both sit at `/workspace/app`; a laptop and a cloud box run the same
  branch at the same path with different uncommitted state. Nothing derivable
  from the checkout alone can separate them, which is why `harnesses` never keyed
  on root — and why issue `cb01ce40` (five groups of byte-identical rows on this
  project) cannot be fixed at the working-copy level at all.

  The machine is what disambiguates, so the copy has to say which one it is on.
  An 8-character id shown on the row is not this: it distinguishes the rows
  without telling you anything about them. "Which box is that on" is the question.

  Deliberately uses one path for both copies. Two different paths would pass
  against a page that shows only the path, which is the behaviour this criterion
  exists to rule out.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @shared_path "/workspace/app"

  spex "The machine is what tells two identical checkouts apart" do
    scenario "Two checkouts at the same path on different machines are told apart" do
      given_ "two checkouts of one project at the same path on two different machines",
             context do
        laptop = device_id(context, hostname: "a-laptop", kind: "local")
        sprite = device_id(context, hostname: "a-sprite", kind: "cloud")

        on_laptop = join_working_copy(context, @shared_path, "on the laptop", device_id: laptop)
        on_sprite = join_working_copy(context, @shared_path, "on the sprite", device_id: sprite)

        {:ok,
         context
         |> Map.put(:laptop, laptop)
         |> Map.put(:sprite, sprite)
         |> Map.put(:on_laptop, on_laptop)
         |> Map.put(:on_sprite, on_sprite)}
      end

      when_ "I look at them", context do
        {:ok, live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "each says which machine it is on", context do
        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.on_laptop.working_copy_id}'] [data-test='working-copy-device'][data-device-id='#{context.laptop}']"
               ),
               "the copy on the laptop does not say which machine it is on"

        assert has_element?(
                 context.live,
                 "[data-test='working-copy'][data-working-copy-id='#{context.on_sprite.working_copy_id}'] [data-test='working-copy-device'][data-device-id='#{context.sprite}']"
               ),
               "the copy on the cloud box does not say which machine it is on"

        {:ok, context}
      end

      then_ "and I can tell them apart without reading anything else", context do
        assert context.html =~ "a-laptop" and context.html =~ "a-sprite",
               "both copies are at #{@shared_path}, so the path distinguishes " <>
                 "nothing and neither does an opaque id. The machine's name is " <>
                 "the only thing on the row that answers 'which box is that on'. " <>
                 "Got: #{context.html}"

        {:ok, context}
      end
    end
  end
end
