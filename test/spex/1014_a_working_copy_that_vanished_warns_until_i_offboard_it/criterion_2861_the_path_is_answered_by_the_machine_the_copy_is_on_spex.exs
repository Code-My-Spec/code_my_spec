defmodule CodeMySpecSpex.Story1014.Criterion2861Spex do
  @moduledoc """
  Story 1014 — A working copy that vanished warns until I offboard it.
  Criterion 2861 — The path is answered by the machine the copy is on.

  Rule: Only the harness serving a working copy can say whether its path exists.

  Paths collide, constantly. Every container is at `/workspace/app`; a laptop and
  a cloud box run the same branch at the same path. Story 1020's criterion 2843
  is built on exactly that premise, and it is why identity was made server-issued
  rather than derived from a checkout.

  So "is the checkout still there" cannot be answered by matching a root string,
  and a device reporting one cannot be allowed to speak for a row that points at
  a different machine. `WorkingCopies.observe_paths/2` is scoped to `device_id`
  for that reason, and it is a security boundary rather than a tidiness one: the
  ids arrive from a machine, so without it any device could raise a warning on
  somebody else's laptop by naming its id.

  Deliberately uses one path for both copies. Two different paths would pass
  against an implementation that matched on root, which is the behaviour this
  criterion exists to rule out.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  import CodeMySpecSpex.DeviceHelpers
  import CodeMySpecSpex.PathReportHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "One machine cannot speak for another machine's checkout" do
    scenario "The path is answered by the machine the copy is on" do
      given_ "two working copies at the same path on two different devices, one removed and one intact",
             context do
        laptop = device_id(context, hostname: "a-laptop", kind: "local")
        sprite = device_id(context, hostname: "a-sprite", kind: "cloud")

        # Two real directories, both reported at the same root string. The
        # string is what a naive implementation would match on; the directories
        # are what actually differ.
        shared_root = "/workspace/app"

        on_laptop =
          join_working_copy(context, shared_root, "on the laptop", device_id: laptop).working_copy_id

        on_sprite =
          join_working_copy(context, shared_root, "on the sprite", device_id: sprite).working_copy_id

        laptop_dir = checkout(on_laptop)
        sprite_dir = checkout(on_sprite)

        {:ok,
         context
         |> Map.put(:laptop, laptop)
         |> Map.put(:sprite, sprite)
         |> Map.put(:on_laptop, on_laptop)
         |> Map.put(:on_sprite, on_sprite)
         |> Map.put(:laptop_dir, laptop_dir)
         |> Map.put(:sprite_dir, sprite_dir)}
      end

      when_ "each device's harness reports what it can see", context do
        # The sprite's checkout is thrown away, which is what happens to a
        # sprite. The laptop's is untouched.
        remove(context.sprite_dir)

        laptop_reporter =
          harness(context, context.laptop, %{context.on_laptop => context.laptop_dir})

        report(laptop_reporter)

        sprite_reporter =
          harness(context, context.sprite, %{context.on_sprite => context.sprite_dir})

        report(sprite_reporter)

        {:ok, live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/working-copies")

        {:ok, Map.put(context, :live, live)}
      end

      then_ "only the copy on the device where the checkout was removed is shown as missing",
            context do
        assert has_element?(
                 context.live,
                 "[data-working-copy-id='#{context.on_sprite}'] [data-test='path-missing']"
               ),
               "the sprite's checkout was deleted and its own harness said so, " <>
                 "and the page does not show it as gone"

        {:ok, context}
      end

      then_ "and the other is unaffected by sharing its path string", context do
        refute has_element?(
                 context.live,
                 "[data-working-copy-id='#{context.on_laptop}'] [data-test='path-missing']"
               ),
               "the laptop's checkout is on the laptop and is perfectly fine, but " <>
                 "it shares a root string with the sprite's — so an implementation " <>
                 "that answered by matching roots has just raised a warning about " <>
                 "somebody's laptop on the strength of what a container reported. " <>
                 "The device is what disambiguates; nothing derivable from the " <>
                 "path can."

        {:ok, context}
      end
    end
  end
end
