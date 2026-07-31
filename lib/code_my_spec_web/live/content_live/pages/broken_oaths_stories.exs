[
  %{
    story_id: 873,
    status: :in_progress,
    title: "New Player Spawns in World",
    description:
      "As a new player, I want to spawn with a settler and lord unit in an unexplored region of the hex globe, so that I can begin building my civilization from a safe starting position.

Source: .code_my_spec/stories/stone_age.md §1.1, trimmed to the pre-city substrate: joining an active world (or creating one), spawn placement far from existing players on valid terrain, the two starting units (Lord with crown icon, Settler), 50 starting gold, and the map centering on the spawn point. City founding, barbarians, and the welcome flow build on this in a later batch.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Registered player picks a world and spawns", verified: false},
      %{description: "Picking a world that just filled up fails gracefully", verified: false},
      %{description: "Re-entering a joined world never re-spawns", verified: false},
      %{description: "Returning player resumes where their civilization is", verified: false},
      %{description: "Playing in two worlds at once", verified: false},
      %{description: "Spawn delivers a Lord and a Settler on workable land", verified: false},
      %{description: "Fresh spawn shows 50 gold", verified: false},
      %{description: "A fourth world join is refused at the cap", verified: false},
      %{description: "Abandoning wipes the civilization and reopens the region", verified: false},
      %{description: "An abandoned region is a fresh start for its next claimant", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A player enters play by picking a world with room from the world picker.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Registered player picks a world and spawns",
              body: "Given a registered, logged-in player on the world picker
When they pick a world that has unclaimed regions
Then they are spawned into that world and taken to the board"
            },
            %{
              kind: "failure path",
              title: "Picking a world that just filled up fails gracefully",
              body: "Given a world picker showing a world with one open region
When another player claims that last region before this player clicks join
Then the join is refused with a clear message and the picker reflects the world as full — the player is never half-spawned"
            }
          ]
        },
        %{
          statement: "Joining a world spawns a player exactly once in that world.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Re-entering a joined world never re-spawns",
              body: "Given a player who already spawned in a world
When they open that world again (navigation, refresh, or picker)
Then they see their existing units and gold — no second Lord, Settler, or region claim is created"
            }
          ]
        },
        %{
          statement: "A returning player lands back in their world with the camera on their civilization.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Returning player resumes where their civilization is",
              body: "Given a player with an existing world membership
When they log in and continue playing
Then they land on that world's board with the camera centered on their units"
            }
          ]
        },
        %{
          statement: "A player may hold multiple concurrent world memberships and switch between them from the main menu.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Playing in two worlds at once",
              body: "Given a player already spawned in one world
When they go back to the main menu and join a second world
Then they spawn fresh in the second world, and both memberships remain resumable from the picker"
            }
          ]
        },
        %{
          statement: "A new player spawns with exactly one Lord and one Settler on workable land in their claimed region.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Spawn delivers a Lord and a Settler on workable land",
              body: "Given a new player joining a world
When their spawn completes
Then they own exactly one Lord (crown icon) and one Settler, placed together on workable land (grassland or plains — never ocean, mountains, or marsh) inside their claimed region"
            }
          ]
        },
        %{
          statement: "A new player starts with 50 gold.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fresh spawn shows 50 gold",
              body: "Given a new player joining a world
When the board loads after spawn
Then their gold reads exactly 50"
            }
          ]
        },
        %{
          statement: "A player may hold at most three concurrent world memberships.",
          scenarios: [
            %{
              kind: "failure path",
              title: "A fourth world join is refused at the cap",
              body: "Given a player already playing in three worlds
When they try to join a fourth from the picker
Then the join is refused with a clear message about the three-world limit, and their three existing memberships are untouched"
            }
          ]
        },
        %{
          statement: "A player may abandon a world; abandoning demolishes everything they own and reopens their region.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Abandoning wipes the civilization and reopens the region",
              body: "Given a player with units and holdings in a world
When they abandon the world and confirm the warning
Then everything they owned is removed from the board, their region becomes claimable by new players, and one of their three membership slots is freed"
            },
            %{
              kind: "happy path",
              title: "An abandoned region is a fresh start for its next claimant",
              body: "Given a region reopened by an abandonment
When a new player claims it
Then they spawn into it exactly like any fresh region — no leftover units, holdings, or ownership traces from the previous player"
            }
          ]
        }
      ],
      questions: [
        %{body: "Exact cap on concurrent world memberships — PM floated \"about three\". Pin the number (and what the player sees at the cap) before implementing the picker.", status: :resolved, resolution: nil},
        %{body: "Join-with-a-friend placement (spawn in adjacent regions?) — PM wants the door left open. What does the picker need now so friend co-placement can land later without rework?", status: :open, resolution: nil},
        %{body: "Abandon mechanic details PM hasn't decided: does it resolve immediately or at the turn boundary? Any cooldown before rejoining the same world (grief/re-roll prevention)? And once vassalization exists, can a vassal abandon — and what does their lord get? Demolish-and-reopen is the placeholder.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 874,
    status: :in_progress,
    title: "Automatic Turn Processing",
    description:
      "As a player, I want turns to process automatically every 60 seconds, so that the game progresses continuously for everyone in the world without anyone having to press end-turn.

Source: .code_my_spec/stories/stone_age.md §5.1. The substrate version: a per-world turn timer (GenServer), a visible countdown and turn number in the UI, simultaneous execution of queued orders at the turn boundary, and real-time turn-completion updates to all connected players via PubSub. Production, combat, healing, and barbarian steps hook into this pipeline as they arrive in later batches.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "The countdown runs down and the turn advances by itself", verified: false},
      %{description: "The world lives while everyone sleeps", verified: false},
      %{description: "A server restart never loses or double-runs a turn", verified: false},
      %{description: "Orders execute immediately and the boundary recharges movement", verified: false},
      %{description: "Two connected players tick over together", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "The world's turn advances automatically every 60 seconds; no player ends a turn.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The countdown runs down and the turn advances by itself",
              body: "Given a player watching a world on turn 41 with the countdown visible
When the countdown reaches zero
Then the turn number reads 42 and the countdown resets to 60 seconds without anyone acting"
            }
          ]
        },
        %{
          statement: "Turns keep advancing even when no player is online.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The world lives while everyone sleeps",
              body: "Given a world on turn 100 whose players all disconnect
When ten minutes of wall-clock time pass and a player returns
Then the world is on turn 110 and everything that was queued resolved on schedule"
            },
            %{
              kind: "failure path",
              title: "A server restart never loses or double-runs a turn",
              body: "Given a world mid-turn when the server restarts
When the world comes back up
Then the turn count catches up to wall-clock correctly, and no queued order executes twice or disappears"
            }
          ]
        },
        %{
          statement: "Orders execute immediately with available movement; the turn boundary recharges movement and continues remaining paths.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Orders execute immediately and the boundary recharges movement",
              body: "Given a player who queues a move for a unit with movement points available
When the order lands
Then the unit moves immediately, spending its points — and at the turn boundary movement recharges and any remaining path continues"
            }
          ]
        },
        %{
          statement: "Every player in a world sees the same turn number and countdown in real time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Two connected players tick over together",
              body: "Given two players connected to the same world in separate browsers
When the turn advances
Then both see the new turn number without refreshing, at effectively the same moment"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 875,
    status: :in_progress,
    title: "Queue Movement Orders",
    description:
      "As a player, I want to select a unit and queue a movement order to an adjacent hex between turns, so that my units move when the turn processes.

Source: .code_my_spec/stories/stone_age.md §5.2 plus the selection substrate from more_stories.md §2.3: click a unit to select it and see its details (type, HP, movement remaining), click a destination hex to queue a validated move (terrain, movement points, blocking), see the queued path on the globe, change the order freely before the turn boundary, and have the move resolve — or fail gracefully — when the turn processes. Server-authoritative and LiveView-testable per the board doctrine.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Clicking your lord shows the unit panel", verified: false},
      %{description: "A settler walks a three-hex path: two hexes now, the third after the recharge", verified: false},
      %{description: "A path blocked mid-journey halts the unit without losing it", verified: false},
      %{description: "Only the latest remaining path executes", verified: false},
      %{description: "Ocean and mountains refuse a land unit", verified: false},
      %{description: "Two units racing for the same hex resolve to one occupant", verified: false},
      %{description: "You cannot path onto your own unit", verified: false},
      %{description: "An order into the fog of war is legal: right-clicking an unexplored spot on the globe queues a move there (the client sends the clicked sphere point; the server resolves the tile, since the fog-filtered client can't name tiles it has never seen), and the unit travels through unexplored terrain to reach it.", verified: false},
      %{description: "A queued order's remaining path renders from the unit to its destination and shrinks as the unit walks", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Selecting your unit shows its details: type, hit points, and movement remaining.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Clicking your lord shows the unit panel",
              body: "Given a player viewing their spawn
When they select their Lord
Then the unit panel shows Lord, its hit points, and its movement remaining this turn"
            }
          ]
        },
        %{
          statement: "A player queues a multi-hex path to a destination; the unit follows it across turns at its movement rate.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A settler walks a three-hex path: two hexes now, the third after the recharge",
              body: "Given a selected Settler (movement 2) and a passable destination three hexes away
When the player queues the path
Then the settler advances two hexes immediately (points spent), and completes the final hex when the boundary recharges its movement"
            },
            %{
              kind: "failure path",
              title: "A path blocked mid-journey halts the unit without losing it",
              body: "Given a unit resting mid-path with no movement left, whose next step another unit then occupies
When the boundary recharges and the unit tries that step
Then the unit stops where it is, its order flips to interrupted with the remaining path kept, and the player is informed — the unit is never lost or teleported"
            }
          ]
        },
        %{
          statement: "Orders can be changed or cancelled freely until the turn boundary.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Only the latest remaining path executes",
              body: "Given a unit with its movement already spent this turn
When the player queues one target and then replaces it before the boundary
Then after the recharge the unit follows only the replacement — the earlier order never executes"
            }
          ]
        },
        %{
          statement: "Only valid destinations are accepted: passable terrain reachable by the unit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Ocean and mountains refuse a land unit",
              body: "Given a selected land unit
When the player clicks an ocean tile or an impassable mountain tile
Then no order is queued and the player sees why the destination is invalid"
            }
          ]
        },
        %{
          statement: "One unit per hex; a move into an occupied hex does not happen.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Two units racing for the same hex resolve to one occupant",
              body: "Given two units whose queued paths enter the same hex on the same turn
When the turn boundary resolves
Then exactly one unit occupies the hex and the other halts on its previous tile — deterministically, never both stacked"
            },
            %{
              kind: "happy path",
              title: "You cannot path onto your own unit",
              body: "Given a player's Lord standing on a tile
When they try to queue their Settler's path ending on that same tile
Then the order is rejected at queue time — occupied destinations are invalid"
            }
          ]
        },
        %{
          statement: "When an order is queued, the board renders the pathway from the unit's current position to its destination — the remaining route stays visible (for the owning player only) whenever that unit is selected, updating as movement consumes steps, until the unit arrives or the order is replaced.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A queued order's remaining path renders from the unit to its destination and shrinks as the unit walks",
              body: "Given a player with a selected settler on the board
When the player queues a move to a tile several hexes away
Then the board pushes the remaining path from the settler's current tile to the destination
And after a turn boundary carries the settler forward, re-selecting it shows the path shortened to the steps still ahead
And when the settler arrives, no path renders for it"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 876,
    status: :in_progress,
    title: "Fog of War and Exploration",
    description:
      "As a player, I want to see only the areas of the globe I have explored, so that the game has discovery and scouting mechanics.

Source: .code_my_spec/stories/stone_age.md §7.1. Three per-player visibility states on the hex globe: unexplored (hidden), explored-but-out-of-vision (terrain remembered, greyed, no live units shown), and currently visible (vision radius around own units — Lord sees farther). The exploration mask is server-owned per player and never leaks hidden tiles to the client; each player sees a different world. Cities extend vision when they arrive in a later batch.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A fresh spawn sees a cloud-wrapped planet with one clear bubble", verified: false},
      %{description: "The Lord out-scouts the Settler", verified: false},
      %{description: "Terrain stays on the map after the scout moves on", verified: false},
      %{description: "A stranger in remembered territory is invisible", verified: false},
      %{description: "Two players see two different worlds", verified: false},
      %{description: "Hidden tiles never travel over the wire", verified: false},
      %{description: "Fog cloud and weather cloud read as different things", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Unexplored territory is hidden under opaque cloud cover at every zoom level.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A fresh spawn sees a cloud-wrapped planet with one clear bubble",
              body: "Given a player who just spawned
When they look at the globe at any zoom — including fully zoomed out
Then the planet reads as a whole sphere under opaque cloud cover, with terrain visible only in the vision bubble around their units"
            },
            %{
              kind: "happy path",
              title: "Fog cloud and weather cloud read as different things",
              body: "Given a view containing unexplored fog and weather clouds over explored land
When the player looks at both
Then fog reads as a flat, opaque, colorless shroud while weather clouds stay translucent and day/night-lit — visually distinct at a glance"
            }
          ]
        },
        %{
          statement: "Tiles within vision range of a player's units are fully visible; the Lord sees farther than other units.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The Lord out-scouts the Settler",
              body: "Given a Lord (vision 3) and a Settler (vision 2) standing apart
When the player inspects what is visible
Then tiles within 3 of the Lord and within 2 of the Settler are clear, and the Lord's bubble is visibly larger"
            }
          ]
        },
        %{
          statement: "Explored terrain stays remembered (dimmed) when it falls out of vision.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Terrain stays on the map after the scout moves on",
              body: "Given a unit that explored a valley and then walked away
When the player looks back at the valley
Then its terrain is still shown, dimmed, and it no longer counts as currently visible"
            }
          ]
        },
        %{
          statement: "Units are only shown on tiles currently within vision — remembered terrain shows no live entities.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A stranger in remembered territory is invisible",
              body: "Given another player's unit standing in territory this player explored but no longer watches
When this player views that area
Then they see dimmed terrain and no unit — the stranger only appears if it enters current vision"
            }
          ]
        },
        %{
          statement: "Exploration is per player, and hidden information never reaches a player's client.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Two players see two different worlds",
              body: "Given two players spawned in different regions of the same world
When each looks at their globe
Then each sees only their own explored area clear, and the other's homeland sits under cloud"
            },
            %{
              kind: "failure path",
              title: "Hidden tiles never travel over the wire",
              body: "Given a player with most of the world unexplored
When their client receives board data (tile windows, textures, pushed payloads)
Then unexplored tiles' terrain and other players' units are absent from every payload — not merely painted over — so no client-side inspection can reveal them"
            }
          ]
        }
      ],
      questions: [
        %{body: "Fog clouds vs weather clouds: unexplored area is opaque cloud, but the airspace weather layer also draws (translucent, hex) clouds over explored land. How do players tell them apart visually — different tone/opacity, or does weather simply not render over unexplored area?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 877,
    status: :in_progress,
    title: "Region Placement with Room to Expand",
    description:
      "As a new player, I want to be placed in a region that allows me space for territorial expansion, so that I can grow my civilization without being immediately boxed in by neighbors.

The globe is divided into player regions — bounded territories a player can spawn into and reasonably fill. Source: .code_my_spec/stories/stone_age.md technical notes (~250 hexes per region, supporting 6-8 cities each) and §3.1 (barbarian camps concentrate at region boundaries as natural barriers between players); more_stories.md §1.2 sketches the same idea smaller. This is the mechanism behind \"spawn far from existing players\" in the spawn story: world capacity = number of regions, each new player claims an open one, and region edges are where players eventually meet. Region shape/assignment is server-owned and deterministic from the world seed.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Same seed always produces the same region partition", verified: false},
      %{description: "Every land and coastal tile belongs to exactly one region; deep ocean belongs to none", verified: false},
      %{description: "Two new players land in different regions", verified: false},
      %{description: "Simultaneous joins never double-claim a region", verified: false},
      %{description: "Undersized island regions are never offered for spawning", verified: false},
      %{description: "A full world turns new players away", verified: false},
      %{description: "Mountains and coastal water count as country space", verified: false},
      %{description: "A claimed region has room for about seven cities", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Every world is divided into a fixed set of regions determined entirely by its seed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same seed always produces the same region partition",
              body: "Given a world with seed 424242
When the region partition is computed on two different occasions (including after a server restart)
Then both computations produce identical regions — same tile membership, same region ids"
            },
            %{
              kind: "happy path",
              title: "Every land and coastal tile belongs to exactly one region; deep ocean belongs to none",
              body: "Given a world's region partition
When the regions' tile sets are combined
Then every land tile (including mountains) and every coast-adjacent water tile appears in exactly one region, and deep-ocean tiles belong to no region (unclaimed naval frontier)"
            }
          ]
        },
        %{
          statement: "A region belongs to at most one player; claiming a region is exclusive.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Two new players land in different regions",
              body: "Given a world with unclaimed regions
When two players join the world one after the other
Then each player's claimed region is different, and each sees room to expand around their spawn"
            },
            %{
              kind: "failure path",
              title: "Simultaneous joins never double-claim a region",
              body: "Given a world with exactly one especially desirable unclaimed region
When two players join at the same moment
Then exactly one of them claims that region and the other is placed in a different region — never both in the same one"
            }
          ]
        },
        %{
          statement: "New players are only placed in regions with enough habitable land to support expansion.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Undersized island regions are never offered for spawning",
              body: "Given a world whose landmasses include a small island region too small to support expansion
When a new player joins
Then they are placed in a full-sized region, and the undersized island region remains unclaimed"
            }
          ]
        },
        %{
          statement: "A world with no claimable regions is full and accepts no new players.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A full world turns new players away",
              body: "Given a world where every habitable region is already claimed
When a new player tries to join that world
Then they are not placed in it, and the join flow moves on to a world with capacity (or creates one)"
            }
          ]
        },
        %{
          statement: "A region consists of land (including mountains) plus coast-adjacent water; deep ocean belongs to no region.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Mountains and coastal water count as country space",
              body: "Given a claimed region containing mountain tiles and water tiles adjacent to its coast
When the player inspects their region's extent
Then the mountains and coastal water are inside their region, while open-ocean tiles beyond the coast belong to no one"
            }
          ]
        },
        %{
          statement: "A region is sized to support about seven Civilization-scale cities (roughly 250 hexes).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A claimed region has room for about seven cities",
              body: "Given a new player's claimed region
When its claimable hexes are counted
Then the total is roughly 250 — enough distinct city sites (Civ-scale, ~3-hex working radius each) for about seven cities"
            }
          ]
        }
      ],
      questions: [
        %{body: "What are unclaimable (ocean/mountain-dominated) regions FOR long-term — barbarian territory, naval frontier, future expansion space? Affects whether the partition marks them specially now.", status: :resolved, resolution: nil},
        %{body: "Are region boundaries ever visible to players on the globe (subtle borders at spawn, or fully invisible plumbing)? Affects whether the renderer needs region data at all in batch 1.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 878,
    status: :in_progress,
    title: "Settler Founds City",
    description:
      "As a player, I want to use my settler to found a city, so that I can begin producing resources and units.

Source: .code_my_spec/stories/stone_age.md §2.1 plus more_stories.md §4.2: select the settler and found a city on valid terrain (not ocean/mountains, not too close to another city); the settler is consumed and a size-1 city appears with a default, renameable name; the city claims surrounding territory and can immediately begin production. The stone_age source also triggers barbarian camp spawning on the FIRST city — that consequence belongs to the future barbarian stories, not this one.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A settler founds a city on the grassland it stands on", verified: false},
      %{description: "Founding too close to an existing city is refused with a reason", verified: false},
      %{description: "Founding trades the settler for a working size-1 city on the spot", verified: false},
      %{description: "A fresh city in open land claims exactly seven tiles", verified: false},
      %{description: "A neighbor founded at minimum spacing never steals claimed tiles", verified: false},
      %{description: "A new city is named by default and renameable", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A city is founded on the tile the settler is standing on — walkable land by construction, and the server refuses any non-land tile as a backstop.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A settler founds a city on the grassland it stands on",
              body: "Given a player with a settler selected on a grassland tile far from any city
When the player uses the Found City action
Then a city appears on exactly that tile"
            }
          ]
        },
        %{
          statement: "Founding is refused within 4 hexes of any existing city, regardless of who owns it.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Founding too close to an existing city is refused with a reason",
              body: "Given a player whose settler stands 3 hexes from an existing city
When the player attempts the Found City action
Then no city is created
And the player sees why: too close to an existing city"
            }
          ]
        },
        %{
          statement: "Founding consumes the settler and creates a size-1 city on that tile, immediately (no turn-boundary wait) and immediately able to set production.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Founding trades the settler for a working size-1 city on the spot",
              body: "Given a player with a settler on valid ground
When the player founds a city
Then the settler is gone immediately, before any turn boundary
And a size-1 city stands on the tile
And the player can open it and set production right away"
            }
          ]
        },
        %{
          statement: "A new city claims exactly its own tile plus the six adjacent hexes as territory — expansion beyond that comes from city growth, never from founding (PM decision 2026-07-14: start 1-hex, grow).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A fresh city in open land claims exactly seven tiles",
              body: "Given a settler founding a city with no other city nearby
When the city is created
Then its territory is exactly the city tile plus its six adjacent hexes
And no tile beyond that ring is claimed"
            }
          ]
        },
        %{
          statement: "Tiles already claimed by an existing city stay with that city — a newly founded neighbor never takes them (first-come keeps it).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A neighbor founded at minimum spacing never steals claimed tiles",
              body: "Given an existing city whose territory includes a border tile
And a settler founding a new city exactly 4 hexes away whose ring would cover that same tile
When the new city is created
Then the border tile still belongs to the first city
And the new city's territory simply excludes it"
            }
          ]
        },
        %{
          statement: "A new city receives a default name its owner can rename at any time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A new city is named by default and renameable",
              body: "Given a player who just founded a city
When the city panel opens
Then the city shows a default name
And the owner can change it to a name of their choosing
And the new name persists after leaving and returning to the world"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 879,
    status: :in_progress,
    title: "City Production Queue",
    description:
      "As a player, I want to set production in my cities, so that I can build units and buildings over time.

Source: .code_my_spec/stories/stone_age.md §2.2 plus more_stories.md §5.1: open a city to see current production with a progress bar; choose from Settler (100), Worker (60), Warrior (40), Monument (60); the city accumulates production each turn based on size and worked tiles (size-1 base 5/turn); completed units spawn at the city (or an adjacent hex if occupied); buildings grant bonuses (Monument +2 culture/turn); multiple items can be queued.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "The city panel offers exactly Settler, Worker, and Warrior with costs", verified: false},
      %{description: "A warrior completes after eight turns of flat banking", verified: false},
      %{description: "Progress reads as banked-over-cost mid-build", verified: false},
      %{description: "The queue rolls into the next item and keeps the change", verified: false},
      %{description: "A finished unit lands beside a occupied city tile", verified: false},
      %{description: "A completely blocked city holds the finished unit without losing it", verified: false},
      %{description: "Reordering is free but abandoning mid-build costs the investment", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "The Stone Age production catalog is Settler (100), Worker (60), and Warrior (40) — Monument is deferred until culture has a purpose (PM decision 2026-07-14).",
          scenarios: [
            %{
              kind: "happy path",
              title: "The city panel offers exactly Settler, Worker, and Warrior with costs",
              body: "Given a player who opens their city's panel
When they view the production choices
Then they see Settler (100), Worker (60), and Warrior (40)
And no Monument is offered"
            }
          ]
        },
        %{
          statement: "Every city banks a flat 5 production at each turn boundary; worked-tile production (story 880) stacks on top when it arrives.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A warrior completes after eight turns of flat banking",
              body: "Given a size-1 city that just set Warrior (40) as production
When eight turn boundaries pass
Then the warrior is complete
And a ninth boundary was not needed"
            }
          ]
        },
        %{
          statement: "The city panel always shows the current production item with its banked progress against its cost (e.g. Warrior 25/40).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Progress reads as banked-over-cost mid-build",
              body: "Given a city five turns into building a Warrior (40)
When the player opens the city panel
Then the current production reads Warrior 25/40 with a progress bar"
            }
          ]
        },
        %{
          statement: "Multiple items can be queued; when the current item completes, the next begins automatically and surplus production carries over into it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The queue rolls into the next item and keeps the change",
              body: "Given a city with Warrior then Worker queued
When the warrior completes at a boundary
Then the worker becomes the current production automatically
And any production banked past the warrior's cost counts toward the worker"
            }
          ]
        },
        %{
          statement: "A completed unit spawns on the city tile, or an adjacent free land tile if the city tile is occupied; if no tile is free the finished item waits at the head of the queue until space opens — nothing is lost.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A finished unit lands beside a occupied city tile",
              body: "Given a city whose own tile is occupied by a garrisoned unit
When a new warrior completes
Then the warrior spawns on an adjacent free land tile"
            },
            %{
              kind: "failure path",
              title: "A completely blocked city holds the finished unit without losing it",
              body: "Given a city whose tile and every adjacent land tile are occupied
When production completes
Then the finished unit does not appear anywhere
And it spawns automatically as soon as a tile frees up
And no production is lost in the meantime"
            }
          ]
        },
        %{
          statement: "Queue edits are free — queued items can be reordered or removed anytime; canceling the in-progress item forfeits its invested production (PM decision 2026-07-14: progress sticks to the item).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Reordering is free but abandoning mid-build costs the investment",
              body: "Given a city building a Settler at 60/100 with a Warrior queued behind it
When the player removes the Settler from the queue
Then the Warrior becomes current at 0/40
And the 60 invested production is forfeited"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 880,
    status: :in_progress,
    title: "City Growth",
    description:
      "As a player, I want my cities to grow larger over time, so that they become more productive.

Source: .code_my_spec/stories/stone_age.md §2.3 plus more_stories.md §5.2: cities start at size 1 and accumulate food from worked tiles each turn; the food threshold rises with size (size 2 needs 20, size 3 needs 30); reaching it grows the city by one population; each population works one additional hex (manual assignment or auto-assign); worked hexes yield food/production/gold; Stone Age cap is size 4 (Bronze Age raises it).",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Growth claims exactly one new tile beside the city", verified: false},
      %{description: "Twenty banked food turns a hamlet into a town", verified: false},
      %{description: "Each citizen works one tile beyond the free center", verified: false},
      %{description: "A size-4 city stops growing until the age turns", verified: false},
      %{description: "Yields stack: forested grassland hills feed and build at once", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Each population point gained claims exactly one adjacent unclaimed workable tile (mountains/ice never claimed), auto-picked deterministically: highest total yield, then higher food, then smaller ring distance, then fixed compass order — same map always claims the same tiles (PM decision + Civ research 2026-07-14).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Growth claims exactly one new tile beside the city",
              body: "Given a size-1 city with its founding seven tiles
When it grows to size 2
Then its territory gains exactly one adjacent previously-unclaimed tile
And no other tiles change hands"
            }
          ]
        },
        %{
          statement: "Cities accumulate gross food from worked tiles at each turn boundary (no population food consumption); growth thresholds are 20 / 30 / 40 for sizes 2 / 3 / 4, overflow food carries into the next basket, and at most one growth happens per turn (Civ research 2026-07-14).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Twenty banked food turns a hamlet into a town",
              body: "Given a size-1 city whose worked tiles yield food each boundary
When its accumulated food reaches 20
Then the city becomes size 2
And the growth is visible in the city panel"
            }
          ]
        },
        %{
          statement: "The city center is worked free; each population point works one additional owned workable tile, auto-assigned greedily by 2·food + 1·production (compass tiebreak, deterministic) with a manual override per pop in the city panel.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Each citizen works one tile beyond the free center",
              body: "Given a size-2 city
When the player opens the city panel
Then the center tile shows as always worked
And exactly two more territory tiles are marked worked
And the player can reassign which tiles those are"
            }
          ]
        },
        %{
          statement: "Stone Age cities cap at size 4 — food still accumulates but no further growth occurs until a later age raises the cap.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A size-4 city stops growing until the age turns",
              body: "Given a size-4 city with abundant food income
When many turn boundaries pass
Then the city remains size 4
And no error or loss occurs — the cap is quiet"
            }
          ]
        },
        %{
          statement: "Worked-tile yields compose as base + relief + feature (stacking, Civ VI model): grassland 2F, plains 1F1P, tundra/coast/ocean 1F, desert and snow 0; hills and woods each add +1P; rainforest and marsh each add +1F; mountains and ice are unworkable; the free-worked city center always yields at least 2F1P. Canonical table: .code_my_spec/knowledge/stone_age_yields.md.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Yields stack: forested grassland hills feed and build at once",
              body: "Given a city working a grassland tile with hills and woods
When the boundary's yields accrue
Then that tile contributes 2 food and 2 production
And a worked flat desert tile contributes nothing
And the city center on snow still contributes its 2 food 1 production floor"
            }
          ]
        }
      ],
      questions: [
        %{body: "Exact Stone Age yield table (food/production/gold per base × relief × feature) — PM requested Civ VI research before locking numbers; civ-research agent running. Resolve with the researched table, then add the yield rule + scenario to this story.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 881,
    status: :in_progress,
    title: "Stone Age Warrior Production",
    description:
      "As a player, I want to build warrior units, so that I can defend my cities and eventually push back threats.

Source: .code_my_spec/stories/stone_age.md §4.2 plus more_stories.md §4.4: cities produce Warriors for 40 production; stats Strength 10 / Defense 10 / HP 100; one hex movement per turn (rides the existing movement/turn substrate); heal 10 HP/turn stationary in friendly territory, 15 HP/turn garrisoned in a city. Combat resolution itself (attacking units/camps) is the future combat stories — this story delivers the producible, movable, healing unit.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A city turns 40 production into a warrior on the map", verified: false},
      %{description: "A warrior walks one hex per turn while a settler walks two", verified: false},
      %{description: "Resting at home heals; garrison heals faster; the road heals nothing", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Warriors cost 40 production and enter play with Strength 10, Defense 10, HP 100 — and the whole game adopts the 100-point HP scale: existing Lords rescale to 150 HP and Settlers to 50 HP (PM decision 2026-07-14).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A city turns 40 production into a warrior on the map",
              body: "Given a city that completes Warrior production
When the unit spawns
Then a warrior with 100/100 HP and movement 1 stands at the city
And existing lords and settlers show 150 and 50 max HP respectively"
            }
          ]
        },
        %{
          statement: "Warriors move one hex per turn on the existing movement substrate — same ordering, pathing, and fog rules as every other unit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A warrior walks one hex per turn while a settler walks two",
              body: "Given a warrior and a settler queued on long paths
When a turn boundary recharges movement
Then the warrior advances one hex
And the settler advances two"
            }
          ]
        },
        %{
          statement: "A damaged unit standing in its owner's territory heals 10 HP at the boundary if it spent no movement that turn; garrisoned on its own city's tile it heals 15 instead. Outside friendly territory nothing heals.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Resting at home heals; garrison heals faster; the road heals nothing",
              body: "Given three damaged warriors: one resting in home territory, one garrisoned in its city, one resting outside any territory
When a turn boundary passes with none of them moving
Then the one at home gains 10 HP
And the garrisoned one gains 15 HP
And the one abroad gains nothing"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 882,
    status: :in_progress,
    title: "Worker Improves Terrain",
    description:
      "As a player, I want to build workers to improve hexes, so that my cities generate more resources.

Source: .code_my_spec/stories/stone_age.md §4.3 plus more_stories.md §4.3: cities produce Workers for 60 production; workers move like other units; a selected worker can build improvements — Farm on plains/grassland (3 turns, +2 food), Mine on hills (5 turns, +2 production), Road on any land (2 turns, +1 movement); progress shows while building; completed improvements feed the owning city's yields. Workers are fragile (1 HP, no combat) — vulnerability consequences arrive with the barbarian/combat stories.

Playtest update (issue 1caa87e9 — worker charges): workers have a limited number of BUILD CHARGES, following Civ 6 Builder conventions. In Civ 6 a Builder is created with 3 charges (base), consumes one charge per completed improvement, and is expended (removed from the map) the moment its last charge is spent; roads are NOT built with charges in Civ 6 (Traders and automatic road-laying handle roads, not Builders). Broken Oaths (product-owner CONFIRMED): a worker is created with 3 build charges; each COMPLETED Farm or Mine consumes exactly one charge; a worker that finishes its last-charge improvement is expended and removed from the map in the same step. Roads are CHARGE-EXEMPT — building a Road consumes no charge (matching Civ 6, and roads are a deferred worker improvement here). Charges are consumed only on COMPLETION, not on starting or abandoning a build, so an abandoned dig costs no charge. The remaining charge count is shown on the selected worker (e.g. \"3 charges\"). This turns the worker from a permanent unit into a consumable investment — ~60 production buys roughly 3 Farm/Mine improvements — so players build workers on an ongoing basis rather than keeping one forever.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A worker is a builder, not a fighter", verified: false},
      %{description: "Three turns of digging turns grassland into a farm", verified: false},
      %{description: "A worker helps a friend by farming their land", verified: false},
      %{description: "An abandoned dig waits patiently for the next shovel", verified: false},
      %{description: "A finished mine pays its city and refuses a second improvement", verified: false},
      %{description: "A fresh worker comes with three charges", verified: false},
      %{description: "Three farms and the worker is spent", verified: false},
      %{description: "An abandoned dig costs no charge", verified: false},
      %{description: "The charge count is on the selected worker", verified: false},
      %{description: "Roads are free of charge", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Workers cost 60 production, move on the standard substrate, and cannot fight — 10 HP on the 100-scale; combat consequences for them arrive with the barbarian/combat stories.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A worker is a builder, not a fighter",
              body: "Given a city that completes Worker production
When the worker spawns
Then it has 10 HP and moves like other units
And it offers Build Improvement actions instead of any combat action"
            }
          ]
        },
        %{
          statement: "A selected worker can start a Farm on flat, featureless grassland or plains (3 turns, +2 food) or a Mine on hills (5 turns, +2 production); Roads are deferred to their own story and will reduce movement cost when movement costs exist (PM decision 2026-07-14).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Three turns of digging turns grassland into a farm",
              body: "Given a worker standing on flat featureless grassland
When the player starts a Farm and three turn boundaries pass
Then the farm is complete on that tile
And starting a Farm on a hills or forested tile is not offered"
            }
          ]
        },
        %{
          statement: "Improvements can be built anywhere passable — wilderness and other players' territory included (no open-borders system restricts it yet); water and mountains refuse (PM decision 2026-07-14).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A worker helps a friend by farming their land",
              body: "Given a worker standing on valid farmland inside a friendly player's territory
When the worker's owner starts a Farm and it completes
Then the farm exists on that tile
And it feeds whichever city works the tile — the friend's city, in this case
And nothing prevents building on any player's territory (no open-borders system yet)"
            }
          ]
        },
        %{
          statement: "Build progress accrues one step per turn boundary while a worker stands on the tile, and sticks to the tile — an interrupted build resumes where it left off when any of the owner's workers returns.",
          scenarios: [
            %{
              kind: "happy path",
              title: "An abandoned dig waits patiently for the next shovel",
              body: "Given a worker two turns into a five-turn mine
When the worker walks away and later a different worker of the same player returns to the tile and resumes
Then the mine completes after three more boundaries
And no progress was lost"
            }
          ]
        },
        %{
          statement: "A tile holds at most one improvement; a completed farm or mine feeds whichever city works that tile (+2 food / +2 production through the yield system), and building over an existing improvement is refused.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A finished mine pays its city and refuses a second improvement",
              body: "Given a completed mine on a hills tile worked by a city
When the next boundary's yields accrue
Then the city's production income includes the mine's +2
And a worker attempting a new improvement on that tile is refused"
            }
          ]
        },
        %{
          statement: "A newly built worker starts with 3 build charges.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A fresh worker comes with three charges",
              body: "Given a city finishes producing a worker for 60 production
When the worker appears on the map
Then it has 3 build charges available"
            }
          ]
        },
        %{
          statement: "A worker spends one build charge for each Farm or Mine it completes, and is expended and removed from the map when it spends its last charge.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Three farms and the worker is spent",
              body: "Given a worker with 3 build charges
When it completes a Farm, then moves and completes a second Farm, then a third Farm
Then each completed Farm drops its charge count from 3 to 2 to 1 to 0
And when the third Farm completes the worker is expended and removed from the map
And all three Farms remain and feed their cities' yields"
            },
            %{
              kind: "failure path",
              title: "An abandoned dig costs no charge",
              body: "Given a worker with 3 build charges that has started but not finished a Mine
When the player cancels the build before it completes
Then the worker still has 3 build charges
And the worker is not expended"
            }
          ]
        },
        %{
          statement: "A selected worker shows how many build charges it has remaining.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The charge count is on the selected worker",
              body: "Given a worker that has completed one Farm and has 2 charges left
When the player selects that worker
Then the worker panel shows \"2 charges\" remaining"
            }
          ]
        },
        %{
          statement: "Building a Road does not consume a build charge — roads are charge-exempt.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Roads are free of charge",
              body: "Given a worker with 2 build charges left
When it completes a Road on a land tile
Then the worker still has 2 build charges
And the worker is not expended and can still build a Farm or Mine"
            }
          ]
        }
      ],
      questions: [
        %{body: "Roads: in Civ 6, Builders never spend charges on roads (Traders/auto-roads build them). Here Road is a worker improvement but is deferred. Default proposal is that building a Road does NOT consume a build charge (charge-exempt). Confirm roads are charge-exempt, or decide roads should cost a charge like Farm/Mine, when roads are eventually implemented.", status: :resolved, resolution: nil},
        %{body: "Is 3 build charges the right number for Broken Oaths (Civ 6 Builder base is 3)? At 60 production for ~3 improvements, confirm the production-per-improvement economics feel right, or tune the charge count / worker cost in playtest.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 883,
    status: :in_progress,
    title: "Settler Production and Expansion",
    description:
      "As a player, I want to build additional settlers, so that I can found more cities and expand my civilization.

Source: .code_my_spec/stories/stone_age.md §4.4: cities produce Settlers for 100 production; completing one costs the city 1 population, and a size-1 city cannot produce a settler (it would destroy the city); settlers move 2 hexes per turn; new cities must be at least 4 hexes from existing cities; founding additional cities does NOT spawn more barbarian camps (the first-city trigger is one-time).",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A settler is paid for in people", verified: false},
      %{description: "A hamlet may not empty itself onto the road", verified: false},
      %{description: "The map remembers what the census forgets", verified: false},
      %{description: "The second city is founded like the first, minus the drama", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Settlers cost 100 production, and completing one costs the producing city one population point at the moment it spawns.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A settler is paid for in people",
              body: "Given a size-2 city completing Settler production
When the settler spawns
Then the city drops to size 1
And the settler stands ready with 2 movement"
            }
          ]
        },
        %{
          statement: "A size-1 city cannot select Settler as production — the choice is disabled with the reason (completing it would destroy the city).",
          scenarios: [
            %{
              kind: "failure path",
              title: "A hamlet may not empty itself onto the road",
              body: "Given a size-1 city
When the player opens the production choices
Then Settler is disabled with the reason
And it becomes selectable once the city grows to size 2"
            }
          ]
        },
        %{
          statement: "Losing population to a settler un-works a tile but never un-claims territory — once claimed, a city's tiles are permanent.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The map remembers what the census forgets",
              body: "Given a size-2 city that grew once and so claims eight tiles
When it completes a settler and drops to size 1
Then it still claims all eight tiles
And only one worked tile remains beyond the free center"
            }
          ]
        },
        %{
          statement: "A produced settler founds cities under the story-878 rules (walkable land, 4-hex spacing), and founding additional cities never triggers extra barbarian consequences — the first-city trigger is one-time and belongs to the barbarian stories.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The second city is founded like the first, minus the drama",
              body: "Given a produced settler marched 4+ hexes from the first city
When it founds a second city
Then the founding follows the same terrain and spacing rules as the first
And nothing else changes in the world because of it"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 891,
    status: :in_progress,
    title: "Unit Combat",
    description:
      "As a player, I want to attack adjacent enemy units with my military units, so that I can defend my territory and clear threats.

Source: .code_my_spec/stories/stone_age.md §10.1 plus combat clauses of §4.2: select a military unit or lord, attack an adjacent hostile unit; damage = strength − defense ± randomness (~20%); defender counter-attacks; both sides lose HP on the 100-HP scale; destruction at 0 HP removes the unit; combat result surfaced to the player; attacking exhausts the attacker's movement for the turn; retreating (moving away) is always an alternative. Lord grants +2 strength to adjacent friendly attackers (the aura itself is the Lord story; this story consumes it if present). Exact formula and randomness are Three Amigos decisions anchored to .code_my_spec/knowledge/stone_age_yields.md conventions.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Warrior strikes the barbarian next door", verified: false},
      %{description: "Two tiles is too far", verified: false},
      %{description: "The blow lands now, not at the boundary", verified: false},
      %{description: "Spent units cannot swing", verified: false},
      %{description: "The stronger side hits harder", verified: false},
      %{description: "The killing blow is not free", verified: false},
      %{description: "Zero HP means gone", verified: false},
      %{description: "The battle report", verified: false},
      %{description: "Fighting beside the lord", verified: false},
      %{description: "No friendly fire in the Stone Age", verified: false},
      %{description: "A dying warrior swings soft", verified: false}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A military unit or lord can attack a hostile unit only on an adjacent tile.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Warrior strikes the barbarian next door",
              body: "Given my warrior stands adjacent to a barbarian warrior
When I order my warrior to attack the barbarian
Then both units lose HP"
            },
            %{
              kind: "failure path",
              title: "Two tiles is too far",
              body: "Given my warrior stands two tiles from a barbarian warrior
When I order my warrior to attack the barbarian
Then the attack is refused with a human-readable reason and neither unit loses HP"
            }
          ]
        },
        %{
          statement: "An attack resolves immediately when ordered and consumes all of the attacker's remaining movement.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The blow lands now, not at the boundary",
              body: "Given my warrior has movement remaining and stands adjacent to a barbarian
When I order the attack
Then damage applies before any turn boundary passes
And my warrior's remaining movement is 0"
            },
            %{
              kind: "failure path",
              title: "Spent units cannot swing",
              body: "Given my warrior has 0 movement remaining and stands adjacent to a barbarian
When I order the attack
Then the attack is refused with a human-readable reason
And after the next turn boundary recharges movement the same attack succeeds"
            }
          ]
        },
        %{
          statement: "Combat damage follows the Civ VI curve: 30 base damage at equal strength, scaled about 4 percent per point of strength difference, with a plus-or-minus 25 percent random roll.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The stronger side hits harder",
              body: "Given my warrior (strength 10) attacks a barbarian warrior (strength 15)
When the combat resolves
Then the barbarian loses damage in the weaker band (roughly 18 to 31)
And my warrior loses damage in the stronger band (roughly 27 to 46)"
            }
          ]
        },
        %{
          statement: "Attacker and defender damage each other simultaneously, both computed from pre-combat state, so a dying defender still lands its counter-blow.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The killing blow is not free",
              body: "Given a barbarian warrior weak enough that my next hit destroys it
When my warrior attacks and destroys it
Then my warrior still takes the barbarian's counter-damage computed from pre-combat stats"
            }
          ]
        },
        %{
          statement: "A unit that reaches 0 HP is destroyed and removed from the world.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Zero HP means gone",
              body: "Given a combat where one unit's HP falls to 0
When the combat resolves
Then that unit disappears from the board and from its owner's unit list
And its tile becomes free for movement"
            }
          ]
        },
        %{
          statement: "The attacking player sees the combat result: damage dealt and damage taken.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The battle report",
              body: "Given my warrior attacks a barbarian
When the combat resolves
Then I see a combat result showing damage dealt and damage taken"
            }
          ]
        },
        %{
          statement: "An attacker adjacent to its own lord fights with +2 strength.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fighting beside the lord",
              body: "Given my warrior stands adjacent to both my lord and a barbarian
When my warrior attacks the barbarian
Then the damage dealt comes from the strength-12 band, not the strength-10 band"
            }
          ]
        },
        %{
          statement: "Attacks against another player's units are refused in the Stone Age; only barbarians are attackable.",
          scenarios: [
            %{
              kind: "failure path",
              title: "No friendly fire in the Stone Age",
              body: "Given my warrior stands adjacent to another player's warrior
When I order an attack on that unit
Then the attack is refused with a reason explaining Stone Age players cannot fight each other"
            }
          ]
        },
        %{
          statement: "A wounded unit fights at reduced effective strength, falling linearly from 100 percent at full HP to 50 percent near death, and all combat math consumes effective strength.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A dying warrior swings soft",
              body: "Given one warrior at full HP and another at 20 of 100 HP, each attacking an identical barbarian
When both combats resolve
Then the wounded warrior's damage comes from a visibly lower band than the fresh warrior's (roughly strength 6 versus strength 10)"
            }
          ]
        }
      ],
      questions: [
        %{body: "Do wounded units deal reduced damage (Civ VI wounded penalty)? Proposed default: no penalty in the Stone Age; damage depends only on strength.", status: :resolved, resolution: nil},
        %{body: "891 specs need a hostile unit to exist. Sequence unit-combat specs after story 892 (camps spawn barbarians), or add a test-only hostile spawner fixture?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 892,
    status: :in_progress,
    title: "Barbarian Camps Spawn",
    description:
      "As a player, I want barbarian camps to form after I found my first city, so that I face a meaningful PvE challenge before I meet other players.

Source: .code_my_spec/stories/stone_age.md §3.1: founding a player's FIRST city spawns 4-6 camps in unexplored hexes 8-15 hexes out, concentrated toward region boundaries, with 1-2 inside the region; camps have 100 HP, render as a distinct camp marker once discovered, and spawn 1 Barbarian Warrior every 3 turns; barbarian warriors outclass Stone Age warriors (nominal 15/15/120 vs 10/10/100); destroying a camp stops its spawning and pays 30 gold (destruction mechanics live in Camp Assault); already-spawned units keep roaming. Founding ADDITIONAL cities spawns nothing (§4.4). Counts, radii, and cadence are Three Amigos decisions; the story owns the spawn trigger, placement, and spawn loop.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "The wilderness answers the first city", verified: false},
      %{description: "Expansion is not punished twice", verified: false},
      %{description: "A camp discovered is a camp marked", verified: false},
      %{description: "Fog keeps its secrets", verified: false},
      %{description: "The camp breeds on a cadence", verified: false},
      %{description: "The cap holds overnight", verified: false},
      %{description: "Born mean", verified: false},
      %{description: "The attention warning", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Founding a player's first city spawns 4 to 6 barbarian camps in unexplored tiles 8 to 15 hexes away, biased toward region boundaries, plus 1 to 2 inside the player's region.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The wilderness answers the first city",
              body: "Given I have no cities and my settler founds my first city
When the founding resolves
Then 5 to 8 camps exist targeting my region, every one 8 to 15 hexes from my city on tiles I have not explored
And 1 to 2 of them sit inside my region"
            }
          ]
        },
        %{
          statement: "Founding any city after the first spawns no camps.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Expansion is not punished twice",
              body: "Given I already have a city and its camps exist
When I found a second city
Then the world's camp count is unchanged"
            }
          ]
        },
        %{
          statement: "A camp has 100 HP and appears as a distinct camp marker only once a player has explored its tile.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A camp discovered is a camp marked",
              body: "Given a camp sits on a tile I have not explored
When my unit walks close enough to bring the tile into vision
Then the camp marker appears on my board with 100 HP"
            },
            %{
              kind: "failure path",
              title: "Fog keeps its secrets",
              body: "Given a camp sits on a tile I have never explored
When my board renders
Then no camp data for that tile travels to my client at all"
            }
          ]
        },
        %{
          statement: "A camp keeps at most 2 of its warriors alive at once, re-spawning one every 3 turns only while below that cap.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The camp breeds on a cadence",
              body: "Given a camp with no living warriors
When 3 turn boundaries pass
Then the camp has spawned exactly 1 barbarian warrior"
            },
            %{
              kind: "failure path",
              title: "The cap holds overnight",
              body: "Given a camp already has 2 living warriors
When 9 turn boundaries pass
Then the camp still has exactly 2 warriors
And killing one lets the camp spawn a replacement within 3 more turns"
            }
          ]
        },
        %{
          statement: "Barbarian warriors carry superior stats: strength 15, defense 15, 120 HP.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Born mean",
              body: "Given a camp spawns a barbarian warrior
When I inspect that unit
Then it carries strength 15, defense 15, and 120 HP"
            }
          ]
        },
        %{
          statement: "The player is warned when their first city triggers camp formation.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The attention warning",
              body: "Given my settler founds my first city
When the founding resolves
Then I see a message that my city has attracted attention and camps are forming in the wilderness"
            }
          ]
        }
      ],
      questions: [
        %{body: "Two players share a region boundary: does each first-city founding spawn its own full camp set (possible pile-up in the shared borderland), or should placement skip tiles already within 8 hexes of an existing camp?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 893,
    status: :in_progress,
    title: "Barbarian Behavior",
    description:
      "As a player, I want barbarians to hunt, attack, and pillage on their own, so that the wilderness stays dangerous without another human involved.

Source: .code_my_spec/stories/stone_age.md §3.2: each turn boundary, barbarian units move 1 hex toward the nearest visible player unit or city; they attack player units on sight (no diplomacy), prioritize undefended cities over units, and never attack each other; moving onto a completed improvement pillages it (improvement removed from the tile); defeating a barbarian pays a small gold bounty (~10). City-attack resolution and garrison math belong to City Defense and Garrison; unit-vs-unit resolution belongs to Unit Combat — this story owns target selection, movement AI, and pillaging.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "The hunt closes in", verified: false},
      %{description: "Out of sight, out of mind", verified: false},
      %{description: "No parley", verified: false},
      %{description: "They smell the undefended city", verified: false},
      %{description: "Honor among savages", verified: false},
      %{description: "The farm burns but the field remains", verified: false},
      %{description: "The bounty", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "At each turn boundary a barbarian moves 1 hex toward the nearest player unit or city within 5 hexes.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The hunt closes in",
              body: "Given a barbarian stands 3 hexes from my warrior and nothing else is nearer
When a turn boundary passes
Then the barbarian is 2 hexes from my warrior"
            }
          ]
        },
        %{
          statement: "A barbarian with no target within 5 hexes roams near its home camp instead of marching.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Out of sight, out of mind",
              body: "Given my nearest unit and city are 9 hexes from a barbarian
When several turn boundaries pass
Then the barbarian stays in the neighborhood of its camp and never closes on my city"
            }
          ]
        },
        %{
          statement: "A barbarian adjacent to a player unit at the boundary attacks it; no diplomacy is possible.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No parley",
              body: "Given a barbarian stands adjacent to my worker at the boundary
When the boundary resolves
Then the barbarian has attacked and my worker has lost HP or died"
            }
          ]
        },
        %{
          statement: "When both an undefended city and a unit are in range, the barbarian goes for the city.",
          scenarios: [
            %{
              kind: "happy path",
              title: "They smell the undefended city",
              body: "Given my ungarrisoned city and my warrior are both within 5 hexes of a barbarian
When turn boundaries pass
Then the barbarian's path heads for the city, not the warrior"
            }
          ]
        },
        %{
          statement: "Barbarians never attack each other.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Honor among savages",
              body: "Given two barbarians from different camps stand adjacent
When turn boundaries pass
Then neither loses HP"
            }
          ]
        },
        %{
          statement: "A barbarian entering a tile with a completed improvement pillages it: yields stop until a worker repairs it in 1 turn.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The farm burns but the field remains",
              body: "Given my city works a completed farm yielding +2 food
When a barbarian walks onto the farm tile
Then the farm shows as pillaged and the +2 food disappears from my city's income
And a worker on that tile restores the farm and its yield in 1 turn"
            }
          ]
        },
        %{
          statement: "Killing a barbarian pays its killer's owner 10 gold.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The bounty",
              body: "Given my warrior's next attack will destroy a barbarian
When the attack resolves
Then my gold increases by 10"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 894,
    status: :in_progress,
    title: "Camp Assault",
    description:
      "As a player, I want to destroy barbarian camps, so that they stop spawning warriors and I can claim the land.

Source: .code_my_spec/stories/stone_age.md §10.2: a military unit adjacent to a camp can attack it; the camp (100 HP) does not counter-attack; damage scales with unit strength, so clearing takes multiple turns; at 0 HP the camp is destroyed, the attacker's owner receives 30 gold, spawning stops, and the hex reverts to normal terrain (city founding and improvements allowed there); barbarian units already spawned remain. Depends on Unit Combat for the attack verb and Barbarian Camps Spawn for the target.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Free hits on the tents", verified: false},
      %{description: "Strength is the shovel", verified: false},
      %{description: "The camp falls and the land opens", verified: false},
      %{description: "Orphans keep fighting", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A military unit adjacent to a camp can attack it, and the camp never counter-attacks.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Free hits on the tents",
              body: "Given my warrior stands adjacent to a discovered camp
When I order an attack on the camp
Then the camp loses HP and my warrior loses none"
            }
          ]
        },
        %{
          statement: "An attack on a camp deals flat damage equal to the attacker's strength, with no random roll.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Strength is the shovel",
              body: "Given a full-health camp at 100 HP
When my warrior (strength 10) hits it and then my lord (strength 12) hits it
Then the camp sits at exactly 78 HP"
            }
          ]
        },
        %{
          statement: "A camp at 0 HP is destroyed: the destroyer's owner earns 30 gold, spawning stops, and the tile reverts to normal terrain open to founding and improvements.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The camp falls and the land opens",
              body: "Given a camp at 10 HP or less
When my warrior lands the final blow
Then the camp disappears, my gold rises by 30, and no new warrior spawns from it after 3 more boundaries
And the former camp tile accepts a city founding or an improvement"
            }
          ]
        },
        %{
          statement: "Warriors already spawned by a destroyed camp remain in the world.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Orphans keep fighting",
              body: "Given a camp with 2 living warriors roaming
When I destroy the camp
Then both warriors remain on the board and still behave as barbarians"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 895,
    status: :in_progress,
    title: "City Defense and Garrison",
    description:
      "As a player, I want my cities to be defensive strongholds I can garrison, so that I survive barbarian attacks while my military grows.

Source: .code_my_spec/stories/stone_age.md §3.3 + §10.3 (one story, two angles): city defensive strength = base (20 + 5 × size) + garrisoned unit defense; units garrisoned in a city gain a +50% defensive bonus and can strike adjacent barbarians from inside; up to 3 units garrison one city; attackers take counter-attack damage from the garrison; city HP regenerates 5/turn when not under attack; at 0 HP the city is pillaged, not captured (loses 1 population, production halts 3 turns, HP resets to 50%); the player is alerted when barbarians close within 3 hexes and when the city is attacked. Depends on Unit Combat and Barbarian Behavior.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "The wall math", verified: false},
      %{description: "Three fit in the keep", verified: false},
      %{description: "The fourth sleeps outside", verified: false},
      %{description: "Fighting from the walls", verified: false},
      %{description: "The walls bite back", verified: false},
      %{description: "Quiet nights mend walls", verified: false},
      %{description: "Sacked but still mine", verified: false},
      %{description: "The watchman's cry", verified: false},
      %{description: "Room in the walls for the meek", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A city has 100 max HP and defensive strength of 20 plus 5 per population plus the defense of its garrison.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The wall math",
              body: "Given my size-2 city has a warrior (defense 10) garrisoned
When I inspect the city
Then its HP shows 100 and its defensive strength shows 40"
            }
          ]
        },
        %{
          statement: "Up to 3 friendly military units may stand on a city tile as garrison — the game's only stacking exception.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Three fit in the keep",
              body: "Given my city tile already holds 2 of my military units
When I move a third onto the city tile
Then it arrives and all 3 count as garrison"
            },
            %{
              kind: "failure path",
              title: "The fourth sleeps outside",
              body: "Given my city tile already holds 3 of my military units
When I order a fourth unit onto the city tile
Then the move is refused with a human-readable reason and the unit stays put"
            }
          ]
        },
        %{
          statement: "A garrisoned unit fights with a +50 percent defensive bonus and can attack adjacent barbarians without leaving the city.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fighting from the walls",
              body: "Given my warrior garrisons my city with a barbarian adjacent
When my warrior attacks the barbarian
Then the attack resolves while my warrior remains on the city tile
And any counter-damage comes from the barbarian's roll against defense 15 (10 plus 50 percent)"
            }
          ]
        },
        %{
          statement: "A barbarian attacking a garrisoned city takes counter-attack damage from the garrison.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The walls bite back",
              body: "Given a barbarian attacks my city while a warrior garrisons it
When the boundary resolves
Then the city loses HP and the barbarian also loses HP"
            }
          ]
        },
        %{
          statement: "A city not attacked since the last boundary regenerates 5 HP per turn, up to its maximum.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Quiet nights mend walls",
              body: "Given my city sits at 80 HP with no barbarian in reach
When 2 turn boundaries pass
Then the city sits at 90 HP"
            }
          ]
        },
        %{
          statement: "A city at 0 HP is pillaged, never captured: it loses 1 population, production halts for 3 turns, and HP resets to 50.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Sacked but still mine",
              body: "Given my size-2 city falls to 0 HP under barbarian attack
When the pillage resolves
Then the city is size 1, still mine, at 50 HP
And its production accumulates nothing for the next 3 boundaries, then resumes with banked progress intact"
            }
          ]
        },
        %{
          statement: "The player is alerted when barbarians close within 3 hexes of their city and again when the city is attacked.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The watchman's cry",
              body: "Given a barbarian marches toward my city
When it crosses within 3 hexes
Then I see an approach alert naming the city
And when it attacks I see an under-attack alert"
            }
          ]
        },
        %{
          statement: "Civilian units may shelter on a friendly city tile; they add no defense and do not count against the 3-unit garrison cap.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Room in the walls for the meek",
              body: "Given my city tile holds 3 garrisoned warriors
When I move my worker onto the city tile
Then the worker arrives, the city's defensive strength is unchanged, and the garrison still counts 3"
            }
          ]
        }
      ],
      questions: [
        %{body: "Can civilian units (worker, settler) also shelter on the city tile, and do they count against the 3-unit garrison cap? Proposed: they may shelter, don't add defense, don't count against the cap.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 896,
    status: :in_progress,
    title: "Lord Leads the Fight",
    description:
      "As a player, I want my lord to be a battlefield anchor, so that I can beat barbarians my plain warriors cannot.

Source: .code_my_spec/stories/stone_age.md §4.1, combat-facing slice: the lord's superior stats (nominal Strength 12 / Defense 12 / HP 150) make it able to win 1v1 against a Barbarian Warrior with retreat-and-heal tactics; the lord grants +2 strength to adjacent friendly units in combat; exactly one lord per player, never disbandable or rebuildable; distinct crown presentation on the board. Already shipped in earlier batches: the lord unit itself, its HP scale, and healing (15/turn in city, 10 in territory... per the healing rules from batch 2). Lord-death consequences (vassal rebellion) stay deferred to the vassalization stories; Three Amigos should decide the interim death behavior.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Braver beside the crown", verified: false},
      %{description: "The aura has an edge", verified: false},
      %{description: "No second crown", verified: false},
      %{description: "The heir takes the throne", verified: false},
      %{description: "You always know the king", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "The lord grants +2 strength to adjacent friendly units in every combat, attacking or defending.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Braver beside the crown",
              body: "Given my warrior stands adjacent to my lord when a barbarian attacks it
When the combat resolves
Then the warrior fights back from the strength-12 band, not the strength-10 band"
            },
            %{
              kind: "failure path",
              title: "The aura has an edge",
              body: "Given my warrior stands 2 hexes from my lord
When it fights a barbarian
Then no +2 bonus applies"
            }
          ]
        },
        %{
          statement: "Each player has exactly one lord lineage: the lord can never be disbanded and never appears in any production catalog.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No second crown",
              body: "Given I open any city's production catalog
When I read the available items
Then no Lord entry exists at any price"
            }
          ]
        },
        %{
          statement: "When the lord dies, his heir arrives at the player's capital 10 turns later as the new lord; leveling penalties arrive with the future leveling system.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The heir takes the throne",
              body: "Given my lord dies in combat
When 10 turn boundaries pass
Then a new lord stands on my capital's tile and I was notified the lineage continues"
            }
          ]
        },
        %{
          statement: "The lord is visually distinguished on the board and in the unit panel by its crown.",
          scenarios: [
            %{
              kind: "happy path",
              title: "You always know the king",
              body: "Given my lord stands on the board
When I look at it or select it
Then its board sprite and unit panel both carry the crown identity"
            }
          ]
        }
      ],
      questions: [
        %{body: "Where does the heir arrive if the player has no cities when the lord dies? Proposed: the player's original spawn tile; revisit when world-exit rules exist.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 897,
    status: :in_progress,
    title: "Configurable Turn Length",
    description:
      "As a player, I want each world to run at its own turn pace, so that QA worlds resolve in seconds while live worlds keep their 60-second rhythm.

PM directive 2026-07-16 (raised during batch-3 Three Amigos): turn_seconds is a per-world field, default 60, set at world creation and immutable after; QA seeds create fast worlds (e.g. 5-second turns) so boundary-dependent tests and QA sessions stop idling a wall-clock minute per turn. The in-game countdown simply reflects the world's own length. No player-facing UI to change it.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A fast world and a slow world coexist", verified: false},
      %{description: "The countdown tells the truth", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Each world carries its own turn length in seconds, set at creation, defaulting to 60, and immutable afterward.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A fast world and a slow world coexist",
              body: "Given one world created with 5-second turns and another created with the default
When both run side by side
Then the fast world advances roughly 12 turns while the default world advances 1"
            }
          ]
        },
        %{
          statement: "All turn-boundary mechanics and the on-screen countdown follow the world's own turn length.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The countdown tells the truth",
              body: "Given I play in a world with 5-second turns
When I watch the top bar
Then the countdown restarts from 5, and food and production tick on that same cadence"
            }
          ]
        }
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 899,
    status: :in_progress,
    title: "Discovering Other Players",
    description:
      "As a player, I want to be notified when my units first gain sight of another player's civilization, so that I know I am no longer alone and can begin interacting with my neighbor.

Source: .code_my_spec/stories/stone_age.md §8.1. When a player's unit or city vision first reveals another player's unit or city, both players are notified (\"You have discovered X's civilization!\"), each is added to the other's \"Known Players\" list, and the pair becomes mutually visible where vision overlaps and unlocked for chat. No PvP in the Stone Age — friendly fire stays disabled; discovery is the gate that turns two strangers into potential collaborators. Depends on Fog of War and Exploration (876) for the vision substrate. Chat itself is the Player-to-Player Chat story; cooperative fighting is the Cooperative Barbarian Fighting story. Notification surfacing and the Known Players UI are Three Amigos decisions.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A scout sighting a stranger triggers discovery", verified: false},
      %{description: "Sighting a barbarian is not discovering a player", verified: false},
      %{description: "Discovery notifies both sides", verified: false},
      %{description: "A known player stays known after leaving sight", verified: false},
      %{description: "Discovery opens the chat channel", verified: false},
      %{description: "Discovered does not mean omniscient", verified: false},
      %{description: "No attacking a discovered player", verified: false},
      %{description: "Discovery is both flashed and logged", verified: false},
      %{description: "The Known Players panel lists discovered civilizations", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:fail, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Discovery fires the first time a player's own vision reveals another player's unit or city.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A scout sighting a stranger triggers discovery",
              body: "Given Wes has never encountered another civilization
When Wes's warrior moves and gains vision of Rival's warrior
Then Wes is shown \"You have discovered Rival's civilization!\"
And Rival is added to Wes's Known Players"
            },
            %{
              kind: "failure path",
              title: "Sighting a barbarian is not discovering a player",
              body: "Given Wes has discovered no civilizations
When Wes's warrior gains vision of a barbarian warrior
Then no discovery notification appears
And Wes's Known Players list stays empty"
            }
          ]
        },
        %{
          statement: "Discovery is mutual and simultaneous: both players are notified and added to each other's Known Players at the same moment.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Discovery notifies both sides",
              body: "Given neither Wes nor Rival has discovered the other
When Wes's vision first reveals Rival's city
Then both Wes and Rival receive a discovery notification
And each player appears in the other's Known Players"
            }
          ]
        },
        %{
          statement: "Once discovered, a player remains in Known Players permanently, even after leaving vision.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A known player stays known after leaving sight",
              body: "Given Wes has discovered Rival
When Rival's units move out of Wes's vision
Then Rival remains in Wes's Known Players list"
            }
          ]
        },
        %{
          statement: "Discovery unlocks player-to-player chat between the two players.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Discovery opens the chat channel",
              body: "Given Wes has not discovered Rival and cannot message him
When Wes discovers Rival
Then a chat conversation with Rival becomes available to Wes"
            }
          ]
        },
        %{
          statement: "A discovered player's units and cities are shown only where the viewer currently has vision; discovery does not grant global sight.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Discovered does not mean omniscient",
              body: "Given Wes has discovered Rival
When Rival's warrior sits on a hex outside Wes's current vision
Then that warrior is not shown on Wes's map
And Rival still appears in Wes's Known Players"
            }
          ]
        },
        %{
          statement: "Discovery never enables combat between players; Stone Age friendly fire stays disabled.",
          scenarios: [
            %{
              kind: "failure path",
              title: "No attacking a discovered player",
              body: "Given Wes has discovered Rival and Wes's warrior is adjacent to Rival's warrior
When Wes selects his warrior and attempts to target Rival's warrior
Then no attack is permitted
And only barbarians remain valid attack targets"
            }
          ]
        },
        %{
          statement: "The discovery notification appears as a transient toast and is also recorded in a persistent events feed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Discovery is both flashed and logged",
              body: "Given Wes discovers Rival
When the discovery fires
Then Wes sees a transient toast announcing it
And an entry for the discovery is added to Wes's events feed"
            }
          ]
        },
        %{
          statement: "A player has a Known Players panel listing every civilization they have discovered.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The Known Players panel lists discovered civilizations",
              body: "Given Wes has discovered Rival and Yuki
When Wes opens the Known Players panel
Then both Rival and Yuki are listed"
            }
          ]
        }
      ],
      questions: [
        %{body: "Discovery trigger scope: does seeing a rival's claimed territory/border or an improvement (e.g. a farm) count as discovery, or only seeing their unit or city?", status: :resolved, resolution: nil},
        %{body: "How should the discovery notification surface — a transient toast/flash, a dismissible modal, and/or an entry in a persistent events feed?", status: :resolved, resolution: nil},
        %{body: "Does this story ship a visible \"Known Players\" panel, or is the known-players list just data that the Player-to-Player Chat story surfaces?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 900,
    status: :in_progress,
    title: "Player-to-Player Chat",
    description:
      "As a player, I want to exchange real-time messages with players I have discovered, so that I can coordinate, negotiate, and socialize without leaving the game.

Source: .code_my_spec/stories/stone_age.md §11.1, merged with more_stories.md §9.1 (In-Game Chat) and §9.2 (Chat Notifications). Chat unlocks between two players once they discover each other; a chat entry point in the main UI opens a panel listing known players; selecting one opens a conversation thread; messages send on enter and arrive in real time via Phoenix PubSub; history persists (last 50 messages per conversation) with sender and timestamp; text only, capped at 500 characters. Unread state surfaces as a badge with a total count and per-contact counts, clearing on open. Depends on Discovering Other Players (the unlock) and the per-world PubSub substrate. Persistence schema, the character limit, and badge behavior are Three Amigos decisions.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Chat is available with a discovered player", verified: false},
      %{description: "No chat with an undiscovered player", verified: false},
      %{description: "Selecting a known player opens the thread", verified: false},
      %{description: "A message arrives in real time", verified: false},
      %{description: "History loads on open", verified: false},
      %{description: "Over-long messages are rejected", verified: false},
      %{description: "Unread badge tracks incoming messages", verified: false},
      %{description: "Older messages page in on demand", verified: false},
      %{description: "Chat is per-world", verified: false},
      %{description: "Profanity is filtered before delivery", verified: false},
      %{description: "Blocking mutes both directions", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A player can chat with another player only after the two have discovered each other.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Chat is available with a discovered player",
              body: "Given Wes has discovered Rival
When Wes opens the chat panel
Then Rival is listed and his conversation can be opened"
            },
            %{
              kind: "failure path",
              title: "No chat with an undiscovered player",
              body: "Given Wes has not discovered Rival
When Wes opens the chat panel
Then Rival does not appear and no conversation with him can be opened"
            }
          ]
        },
        %{
          statement: "The chat panel lists the player's known players, and selecting one opens that conversation thread.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Selecting a known player opens the thread",
              body: "Given Wes has discovered Rival and Yuki
When Wes clicks Rival in the known-players list
Then Rival's conversation thread opens"
            }
          ]
        },
        %{
          statement: "A message sends on enter and appears in the recipient's open conversation in real time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A message arrives in real time",
              body: "Given Wes and Rival both have their conversation open
When Wes types a message and presses enter
Then the message appears in Rival's thread without a reload"
            }
          ]
        },
        %{
          statement: "Opening a conversation loads its most recent 50 messages (each with sender and timestamp); older messages load on demand via a \"load older\" control.",
          scenarios: [
            %{
              kind: "happy path",
              title: "History loads on open",
              body: "Given Wes and Rival have exchanged 60 messages
When Wes opens the conversation
Then the most recent 50 messages are shown, each with sender and timestamp"
            },
            %{
              kind: "happy path",
              title: "Older messages page in on demand",
              body: "Given Wes and Rival have exchanged 120 messages and Wes sees the latest 50
When Wes activates \"load older\"
Then the previous page of messages is prepended to the thread"
            }
          ]
        },
        %{
          statement: "Chat messages are plain text and capped at 500 characters.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Over-long messages are rejected",
              body: "Given Wes is composing a message
When Wes tries to send 501 characters
Then the message is not sent
And Wes is held within the 500-character limit"
            }
          ]
        },
        %{
          statement: "Unread incoming messages raise a badge with a total and per-conversation count, cleared when the conversation is opened.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Unread badge tracks incoming messages",
              body: "Given Wes has the chat panel closed
When Rival sends Wes a message
Then Wes's chat badge shows one unread
And opening Rival's conversation clears it"
            }
          ]
        },
        %{
          statement: "Conversations are scoped to the world in which the two players met.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Chat is per-world",
              body: "Given Wes and Rival discovered each other in world A and share no discovery in world B
When Wes opens chat in world B
Then Rival does not appear there, and their world-A conversation is unaffected"
            }
          ]
        },
        %{
          statement: "Outgoing message text passes a profanity filter before it is delivered.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Profanity is filtered before delivery",
              body: "Given Wes composes a message containing a banned word
When Wes sends it
Then the delivered message has the banned word masked or the send is rejected"
            }
          ]
        },
        %{
          statement: "A player can block another player, muting messages in both directions.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Blocking mutes both directions",
              body: "Given Wes has blocked Rival
When Rival sends Wes a message
Then Wes does not receive it
And Wes cannot send to Rival while the block stands"
            }
          ]
        }
      ],
      questions: [
        %{body: "Message history: is 50 a hard cap (older messages drop from the UI) or the first page with \"load older\" paging like the support widget?", status: :resolved, resolution: nil},
        %{body: "Conversation scope: is chat scoped per-world (you only talk to players you met in that world) or global to a player's account across worlds?", status: :resolved, resolution: nil},
        %{body: "Moderation for the Stone Age MVP: any profanity filter, rate limiting, or block/mute — or trust-based plain text with none of that for now?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 901,
    status: :in_progress,
    title: "Cooperative Barbarian Fighting",
    description:
      "As a player, I want to team up with a discovered neighbor against barbarians, so that we can clear camps neither of us could take alone and open the border between us.

Source: .code_my_spec/stories/stone_age.md §8.2. Two players who have discovered each other can focus the same barbarian target; their attacks accumulate against a camp or warrior across turns, the barbarian's counter-attacks fall on whichever attacker it faces, and the gold bounty for a kill or camp destruction is shared among the participants. Clearing the barbarians that concentrate on a shared border lets both players expand into the reclaimed land. Depends on Unit Combat (891), Camp Assault (894), and Barbarian Behavior (893) for the fight itself, and on Player-to-Player Chat for the coordination channel. How the bounty splits, and whether cooperation is explicit or emergent from shared targeting, are Three Amigos decisions.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Two allies strike one camp", verified: false},
      %{description: "Combined damage fells a camp over two turns", verified: false},
      %{description: "A barbarian counters only its attacker", verified: false},
      %{description: "Bounty is split in proportion to damage", verified: false},
      %{description: "Sole attacker keeps the whole bounty", verified: false},
      %{description: "Cleared border opens for expansion", verified: false},
      %{description: "Allies form up to coordinate", verified: false},
      %{description: "Even undiscovered attackers share the bounty", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Any players can attack the same barbarian camp or unit, and every attacker's damage counts toward it (no mutual discovery required).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Two allies strike one camp",
              body: "Given Wes and Rival have discovered each other and both stand adjacent to the same barbarian camp
When each attacks the camp on the same turn
Then both attacks land on that camp's HP"
            }
          ]
        },
        %{
          statement: "Damage from multiple players against one barbarian target accumulates across turns toward its HP.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Combined damage fells a camp over two turns",
              body: "Given a barbarian camp at 100 HP with Wes and Rival both attacking it
When their combined attacks over two turns reduce it to 0 HP
Then the camp is destroyed"
            }
          ]
        },
        %{
          statement: "A barbarian's counter-attack falls only on the unit currently attacking it, never on the other cooperating player.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A barbarian counters only its attacker",
              body: "Given a barbarian warrior is adjacent to both Wes's warrior and Rival's warrior
When Wes attacks the barbarian
Then the barbarian's counter-attack damages Wes's warrior only, not Rival's"
            }
          ]
        },
        %{
          statement: "The gold bounty for a felled barbarian or destroyed camp is divided among the players who damaged it, in proportion to the damage each dealt.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Bounty is split in proportion to damage",
              body: "Given Wes dealt 70 of a barbarian camp's damage and Rival dealt 30
When the camp is destroyed
Then the 30-gold bounty is split proportionally, about 21 to Wes and 9 to Rival"
            },
            %{
              kind: "happy path",
              title: "Sole attacker keeps the whole bounty",
              body: "Given only Wes dealt damage to a barbarian
When the barbarian is killed
Then Wes receives the full bounty"
            },
            %{
              kind: "happy path",
              title: "Even undiscovered attackers share the bounty",
              body: "Given Wes and Rival have not discovered each other and are not allied
And both dealt damage to the same barbarian camp
When the camp is destroyed
Then each receives a bounty share proportional to the damage they dealt"
            }
          ]
        },
        %{
          statement: "Clearing the barbarians on a shared border opens the reclaimed land for either player to settle or improve.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleared border opens for expansion",
              body: "Given a barbarian camp on the border between Wes and Rival is destroyed
When the hex reverts to normal terrain
Then either player may found a city or build an improvement there"
            }
          ]
        },
        %{
          statement: "Players can form an explicit alliance to coordinate their campaigns against barbarians.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Allies form up to coordinate",
              body: "Given Wes and Rival have discovered each other
When Wes proposes an alliance and Rival accepts
Then the two are allied and can coordinate their barbarian campaigns"
            }
          ]
        }
      ],
      questions: [
        %{body: "Bounty split rule when multiple players damage the same target: even split among all who dealt damage, proportional to damage dealt, or last-hit-takes-all?", status: :resolved, resolution: nil},
        %{body: "Is cooperation explicit (a formal alliance/party the players opt into) or purely emergent from independently attacking the same barbarian target?", status: :resolved, resolution: nil},
        %{body: "Does bounty-sharing require the two players to have discovered each other, or do any two players who both damage the same camp split it even as strangers?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 902,
    status: :in_progress,
    title: "Stone Age Technology Tree",
    description:
      "As a player, I want to research technologies, so that I can unlock new units and buildings and advance toward the Bronze Age.

Source: .code_my_spec/stories/stone_age.md §6.1, EXPANDED per playtest issue 133b4893 (\"basically copy Civ 6 ... beef up the tech tree\"). Grounded in .code_my_spec/knowledge/civ6_tech_tree.md.

Cities generate science by population (2 per pop per turn) accumulating toward the ONE tech being researched at a time, shown with a progress bar; switching research retains each tech's banked science. This story now defines a fuller Civ-6-style ANCIENT-ERA tech tree WITH PREREQUISITES, mirroring Civ 6's exact Ancient-era shape. A technology cannot be researched until all its prerequisites are complete; the tree shows prerequisite links and each tech's locked / available / completed state (this also resolves the \"prerequisites aren't obvious\" playtest complaint).

TECH LIST — cost (science) | prerequisite | benefit | EXISTING content vs gates FUTURE content. The tech-tree STRUCTURE + prerequisites are defined now; unlocks that need new content become their own later stories.

No prerequisite (tier 1):
- Pottery (50) — Granary, +2 food storage. EXISTING.
- Animal Husbandry (50) — Pasture (+2 food on animal resources, story 905). EXISTING.
- Mining (75) — workers build Mines faster (3 turns not 5). EXISTING.
- Sailing (90) — Galley / Fishing Boats / coastal working. FUTURE (no water/naval content yet).
- Astrology (90) — Holy Site / Shrine / belief. FUTURE (no faith system yet).

After Pottery:
- Writing (90) — Library / science building. FUTURE (flat pop-science only today; no science buildings).
- Irrigation (90) — Plantation improvement. FUTURE (needs plantation-eligible resources).

After Animal Husbandry:
- Archery (90) — Archer (ranged unit). FUTURE (new unit).

After Mining:
- Masonry (100) — Walls / city defense (and Quarry). FUTURE (no walls yet).
- The Wheel (100) — Roads / Heavy Chariot / Water Mill. FUTURE; natural gate for the deferred Road worker-improvement (story 882) when roads ship.
- Bronze Working (100) — advances to the Bronze Age (story 903), unlocks Bronze Spearman & Swordsman, reveals the Copper strategic resource (story 911). EXISTING + gates 911. Selecting it prompts \"This will advance you to Bronze Age. Continue?\".

PREREQUISITE EDGES (Civ-6-accurate): Pottery -> Writing; Pottery -> Irrigation; Animal Husbandry -> Archery; Mining -> Masonry; Mining -> The Wheel; Mining -> Bronze Working. Sailing and Astrology are prerequisite-free. (So reaching the Bronze Age now requires Mining before Bronze Working.)

EXISTING-vs-FUTURE summary: EXISTING unlocks wired now = Pottery (granary), Animal Husbandry (pasture), Mining (faster mines), Bronze Working (Bronze Age / Bronze units / Copper reveal). FUTURE unlocks (structure + prereq defined now, content in later stories) = Sailing, Astrology, Writing, Irrigation, Archery, Masonry, The Wheel. This story does NOT implement those new units/buildings — only the tree structure, costs, and prerequisite gating.

Per-turn science extends the city yield/growth systems (879/880). Exact cost tuning and whether to trim the far-future techs (Sailing/Astrology/Writing/Irrigation, whose subsystems do not exist yet) are Three Amigos / product-owner decisions.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Bigger cities research faster", verified: false},
      %{description: "Science banks toward the chosen tech until it completes", verified: false},
      %{description: "The tree lists the Ancient-era techs with their costs", verified: false},
      %{description: "Mining speeds up worker mines", verified: false},
      %{description: "Pottery unlocks the granary", verified: false},
      %{description: "Bronze Working asks before committing", verified: false},
      %{description: "Research progress is visible", verified: false},
      %{description: "Switching research and returning loses nothing", verified: false},
      %{description: "Animal Husbandry unlocks pastures on animal resources", verified: false},
      %{description: "Bronze Working stays locked until Mining is done", verified: false},
      %{description: "Finishing a prerequisite unlocks its followers", verified: false},
      %{description: "The tree makes prerequisites and state obvious", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A city produces 2 science per turn for each point of its population.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Bigger cities research faster",
              body: "Given Wes has a size-3 city and is researching a technology
When a turn processes
Then 6 science (2 x 3 population) is banked toward that technology"
            }
          ]
        },
        %{
          statement: "Only one technology is researched at a time; each turn's science banks toward it until it completes.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Science banks toward the chosen tech until it completes",
              body: "Given Wes is researching Pottery (50 science) at 6 science per turn
When enough turns pass for banked science to reach 50
Then Pottery completes and its science no longer accrues"
            }
          ]
        },
        %{
          statement: "The Ancient-era tech tree offers eleven technologies: Pottery (50), Animal Husbandry (50), Mining (75), Sailing (90), and Astrology (90) with no prerequisite; Writing (90) and Irrigation (90) after Pottery; Archery (90) after Animal Husbandry; and Masonry (100), The Wheel (100), and Bronze Working (100) after Mining.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The tree lists the Ancient-era techs with their costs",
              body: "Given the player opens the tech tree
Then it lists the eleven Ancient-era technologies with their science costs
And Pottery (50), Animal Husbandry (50), Mining (75), Sailing (90), and Astrology (90) appear with no prerequisite
And Writing (90) and Irrigation (90) appear after Pottery, Archery (90) after Animal Husbandry, and Masonry (100), The Wheel (100), and Bronze Working (100) after Mining"
            }
          ]
        },
        %{
          statement: "Completing a technology immediately applies its unlock to the player.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Mining speeds up worker mines",
              body: "Given Wes has completed Mining
When a worker builds a mine
Then it takes 3 turns instead of the usual 5"
            },
            %{
              kind: "happy path",
              title: "Pottery unlocks the granary",
              body: "Given Wes has completed Pottery
When he opens a city's production options
Then a Granary (+2 food storage) is available to build"
            },
            %{
              kind: "happy path",
              title: "Animal Husbandry unlocks pastures on animal resources",
              body: "Given Wes has completed Animal Husbandry and has an animal-resource tile (from the Tile Resources story)
When a worker builds a Pasture on that tile
Then the tile yields +2 food"
            }
          ]
        },
        %{
          statement: "Choosing to research Bronze Working prompts a confirmation, because completing it advances the player to the Bronze Age.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Bronze Working asks before committing",
              body: "Given Wes selects Bronze Working to research
Then he is warned \"This will advance you to Bronze Age. Continue?\"
And research begins only if he confirms"
            }
          ]
        },
        %{
          statement: "The technology being researched shows a progress bar of banked-over-required science, reachable from the main game UI.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Research progress is visible",
              body: "Given Wes is researching Mining (75) and has banked 30 science
When he views the tech UI
Then a progress bar shows 30 of 75"
            }
          ]
        },
        %{
          statement: "Switching research keeps each technology's banked science; a player can change research and return later with no progress lost.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Switching research and returning loses nothing",
              body: "Given Wes has banked 30 science toward Mining and switches to research Pottery
When he later switches back to Mining
Then Mining still has its 30 banked science"
            }
          ]
        },
        %{
          statement: "A technology whose prerequisite is not yet complete is locked and cannot be selected for research until that prerequisite is researched.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Bronze Working stays locked until Mining is done",
              body: "Given the player has not yet researched Mining
When the player opens the tech tree and tries to research Bronze Working
Then Bronze Working is locked and cannot be selected
And the tree indicates it needs Mining first"
            },
            %{
              kind: "happy path",
              title: "Finishing a prerequisite unlocks its followers",
              body: "Given the player has just completed Pottery
When the player views the tech tree
Then Writing and Irrigation are now available to research
And Mining-gated techs like Bronze Working remain locked until Mining is also complete"
            }
          ]
        },
        %{
          statement: "The tech tree shows each technology's prerequisite links and its locked, available, or completed state.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The tree makes prerequisites and state obvious",
              body: "Given the player has completed Mining and is partway through Bronze Working
When the player views the tech tree
Then Mining shows as completed, Bronze Working shows as available/in-progress, and Masonry and The Wheel show as available
And prerequisite links are drawn from Mining to Masonry, The Wheel, and Bronze Working
And techs whose prerequisites are unmet are shown dimmed/locked"
            }
          ]
        }
      ],
      questions: [
        %{body: "Animal Husbandry's source benefit is \"pastures (+2 food on animal resources)\", but the game currently has no animal-resource tiles. What does Animal Husbandry unlock instead — add animal-resource tiles, give it a different flat benefit, or defer it and ship only 3 techs for now?", status: :resolved, resolution: nil},
        %{body: "If a player switches research before a tech completes, is banked progress kept per-tech (Civ-style: switch away and back later with no loss) or lost on switch? Defaulting to Civ-style retained-per-tech unless decided otherwise.", status: :resolved, resolution: nil},
        %{body: "Tech prerequisites (playtest issue 133b4893 — \"if there are tech prerequisites they aren't obvious\"). The four Stone Age techs are currently independently researchable with no prereqs. Assessment: the immediate problem is UI legibility (the tree should show prereq lines / lock state per civ6_tech_tree.md §6), which is a code/design-phase fix, NOT a new requirement. Separate DESIGN question for the product owner: in Civ 6, Bronze Working requires Mining. Should Broken Oaths add a Mining -> Bronze Working prerequisite (Civ-authentic, makes the tree legibly ordered) or keep all four independent so players can beeline Bronze Working (current design, per civ6_tech_tree.md decision 4)? Do NOT change the story until the PM decides.", status: :resolved, resolution: nil},
        %{body: "Tech-set cutoff: the far-future techs whose subsystems don't exist yet (Sailing -> naval/water, Astrology -> faith, Writing -> science buildings, Irrigation -> plantations) are included now as LOCKED STRUCTURE so the tree reads as Civ-6-complete, with their content deferred to later stories. Confirm keeping them as structure, or trim any until their content stories are scheduled (recommended: keep; trim only if empty/future unlocks confuse players).", status: :open, resolution: nil},
        %{body: "Cost tuning: new techs are priced at 90 (Sailing/Astrology/Writing/Irrigation/Archery) and 100 (Masonry/The Wheel/Bronze Working), keeping existing Pottery/AH 50 and Mining 75. Confirm against the 2-science-per-pop economy (size-4 cap = 8 sci/turn max) or retune — civ6_tech_tree.md suggested flattening Mining and a snappier Bronze Working beeline.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 903,
    status: :in_progress,
    title: "Advancing to Bronze Age",
    description:
      "As a player, I want completing Bronze Working to advance my civilization to the Bronze Age, so that I can field stronger units and more easily push back the barbarians.

Source: .code_my_spec/stories/stone_age.md §6.2. Completing Bronze Working research flips the player to the Bronze Age with a notification (\"You have entered the Bronze Age! New units and buildings unlocked.\"), unlocks the Bronze Spearman (Strength 18 / Defense 18 / HP 120, 60 production — beats a Barbarian Warrior 1v1) and the Bronze Swordsman (20 / 15 / 110, 70 production — offense-focused), raises the city size cap from 4 to 6, and shows Bronze Age status in the player profile. Barbarians keep their Stone Age strength (the tech advantage is the point). Depends on Stone Age Technology Tree (the Bronze Working unlock) and rides the existing production/movement/combat/city-growth substrate (879/880/881/891). Exact stat/cost tuning is a Three Amigos decision.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Bronze Working flips the age", verified: false},
      %{description: "The Spearman outfights a barbarian", verified: false},
      %{description: "Cities grow past the Stone Age cap", verified: false},
      %{description: "A Stone Age city still caps at 4", verified: false},
      %{description: "Barbarians don't scale up with the player", verified: false},
      %{description: "Profile reflects the age", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:fail, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Completing Bronze Working research advances the player to the Bronze Age, with a notification (\"You have entered the Bronze Age! New units and buildings unlocked.\").",
          scenarios: [
            %{
              kind: "happy path",
              title: "Bronze Working flips the age",
              body: "Given Wes confirmed and is researching Bronze Working
When it completes
Then he enters the Bronze Age and sees \"You have entered the Bronze Age! New units and buildings unlocked.\""
            }
          ]
        },
        %{
          statement: "The Bronze Age unlocks the Bronze Spearman (strength 16, HP 120, 60 production), a defensive unit that beats a Barbarian Warrior one-on-one.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The Spearman outfights a barbarian",
              body: "Given Wes is in the Bronze Age and has produced a Bronze Spearman (60 production)
When it fights a Barbarian Warrior (strength 15) one-on-one
Then the Spearman wins the exchange"
            }
          ]
        },
        %{
          statement: "In the Bronze Age a player's cities can grow to size 6, up from the Stone Age cap of 4.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cities grow past the Stone Age cap",
              body: "Given Wes is in the Bronze Age with a size-4 city that has banked enough food to grow
When the city grows
Then it reaches size 5, and may continue growing up to size 6"
            },
            %{
              kind: "failure path",
              title: "A Stone Age city still caps at 4",
              body: "Given Wes has not yet reached the Bronze Age and has a size-4 city with surplus food
When the age has not advanced
Then the city does not grow past size 4"
            }
          ]
        },
        %{
          statement: "Barbarians keep their Stone Age strength when a player reaches the Bronze Age; the tech advantage belongs to the player alone.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Barbarians don't scale up with the player",
              body: "Given Wes reaches the Bronze Age
When barbarian warriors spawn or are inspected
Then they still have their Stone Age strength (15), unchanged by the player's advancement"
            }
          ]
        },
        %{
          statement: "The player's Bronze Age status is shown in their profile.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Profile reflects the age",
              body: "Given Wes is in the Bronze Age
When he views his player profile
Then it shows his age as Bronze Age"
            }
          ]
        }
      ],
      questions: [
        %{body: "Ship both Bronze melee units or just one? With no cavalry in the game, the Spearman's anti-cavalry identity is empty, so the Spearman (defensive, str 16 / HP 120 / 60 prod) and Swordsman (offensive, str 20 / HP 110 / 70 prod) mostly overlap. Keep both differentiated by strength-vs-HP/cost, or cut to a single Bronze unit for the MVP?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 904,
    status: :in_progress,
    title: "Stone Age Progress Indicators",
    description:
      "As a player, I want to see my progress toward the Bronze Age and my Stone Age milestones, so that I understand how close I am to advancing and what I have accomplished.

Source: .code_my_spec/stories/stone_age.md §12.1. A progress panel showing the current age (Stone Age), tech progress toward Bronze Working (science per turn, estimated turns to complete), and running totals — cities founded, barbarian camps destroyed, barbarians killed — plus first-time milestones (first city founded, first barbarian killed, first camp destroyed, first player discovered). Optional achievements (\"Barbarian Hunter\" = 10 barbarians, \"City Builder\" = 3 cities, \"Explorer\" = discover another player) are a stretch goal, decided at Three Amigos. Reads from the tech tree, combat, city, and discovery systems already shipped (879/880/891/894/899); the turns-to-Bronze estimate depends on the science-per-turn rate from Stone Age Technology Tree.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Bronze Age progress at a glance", verified: false},
      %{description: "Career totals so far", verified: false},
      %{description: "Milestones mark on first achievement", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "The progress panel shows the player's current age and progress toward the Bronze Age — science per turn and estimated turns to Bronze Working.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Bronze Age progress at a glance",
              body: "Given Wes is in the Stone Age researching Bronze Working at 8 science per turn with 40 of 100 banked
When he opens the progress panel
Then it shows current age Stone Age, 8 science/turn, and about 8 turns to Bronze Working"
            }
          ]
        },
        %{
          statement: "The progress panel shows running totals: cities founded, barbarian camps destroyed, and barbarians killed.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Career totals so far",
              body: "Given Wes has founded 2 cities, destroyed 1 barbarian camp, and killed 3 barbarians
When he opens the progress panel
Then it shows those three totals: 2 cities, 1 camp, 3 barbarians"
            }
          ]
        },
        %{
          statement: "The progress panel marks first-time milestones: first city founded, first barbarian killed, first camp destroyed, and first player discovered.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Milestones mark on first achievement",
              body: "Given Wes has founded his first city and killed his first barbarian, but has not destroyed a camp or discovered a player
When he opens the progress panel
Then the first-city and first-kill milestones are marked achieved, and the first-camp and first-discovery milestones are not"
            }
          ]
        }
      ],
      questions: [
        %{body: "Are the optional achievements (Barbarian Hunter = 10 barbarians killed, City Builder = 3 cities founded, Explorer = discover another player) in scope for this story, or deferred? The source lists them as optional.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 905,
    status: :in_progress,
    title: "Tile Resources",
    description:
      "As a player, I want special resources to sit on some tiles, so that certain terrain is worth settling near and improving.

Source: introduced as the substrate the tech tree's Animal Husbandry benefit lands on (story 902) and the foundation for future resource-based mechanics. Bonus resources (e.g. Cattle, Sheep, Wheat, Stone) are placed deterministically from the world seed on suitable terrain, shown on the board, and grant a yield bonus when their tile is worked and/or improved — e.g. a Pasture built on an animal resource yields +2 food, gated by Animal Husbandry (story 902). Extends the existing terrain/yields/worker-improvement systems (878-882). This story is a PREREQUISITE for story 902's Animal Husbandry unlock and should be sequenced before the tech-tree batch. See .code_my_spec/knowledge/civ6_resources.md for the Civ 6 grounding.

Playtest update (issue 3e1159d1 — resource density too high): the current default placement density puts resources on too many tiles (\"resources everywhere\"). Civ 6 resources are relatively SPARSE and scattered, not on every tile. The new target: the STANDARD (default) density places roughly ONE resource per 12-15 land tiles — about 7% of land tiles — matching Civ 6's early-game feel, down from the current too-high default. Placement stays deterministic from the world seed (zero RNG), terrain-gated first (each resource only lands on its eligible terrain), then a per-resource density threshold on a stable hash of (world_seed, tile_id) decides placement, with an optional 1-hex spacing reject to avoid clumps. The per-world density SLIDER still exists so players can dial worlds richer or sparser; only its default/midpoint drops to the sparser Civ-like target. Recommended per-resource split ~55% food resources (Cattle/Sheep/Wheat) / ~45% production (Stone). NOTE for the build phase: this requires re-tuning the density constants in code and updating the existing 905 density spex to the lower default.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Same seed, same resources", verified: false},
      %{description: "Resources land on their eligible terrain", verified: false},
      %{description: "An unworked Cattle tile already yields extra", verified: false},
      %{description: "A Pasture on Cattle stacks to five food", verified: false},
      %{description: "Pasture needs Animal Husbandry first", verified: false},
      %{description: "Resources are visible from the first look", verified: false},
      %{description: "A city works its resource tile first", verified: false},
      %{description: "A resource-rich world has more than a sparse one", verified: false},
      %{description: "A standard world is sparsely sprinkled, not carpeted", verified: false},
      %{description: "The default no longer feels like resources everywhere", verified: false},
      %{description: "The slider still reaches richer worlds from a sparse default", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Bonus resources are placed deterministically from the world seed and the world's resource-density setting on eligible terrain — the same seed and density always yield the same resource map, with no RNG.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Same seed, same resources",
              body: "Given two worlds generated from the same seed
When their resource maps are compared
Then the same resources sit on the same tiles in both"
            }
          ]
        },
        %{
          statement: "The Stone Age resource set is Cattle (flat grassland), Sheep (hills), Wheat (flat plains), and Stone (hills).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Resources land on their eligible terrain",
              body: "Given a generated world
When Wes inspects its resource tiles
Then Cattle sit only on flat grassland, Sheep and Stone only on hills, and Wheat only on flat plains"
            }
          ]
        },
        %{
          statement: "An unworked resource tile grants a small base bonus on top of its terrain yield: +1 food for Cattle, Sheep, and Wheat; +1 production for Stone.",
          scenarios: [
            %{
              kind: "happy path",
              title: "An unworked Cattle tile already yields extra",
              body: "Given a Cattle resource on flat grassland (2 food from terrain) with no improvement
When the tile is worked
Then it yields 3 food (2 terrain + 1 resource)"
            }
          ]
        },
        %{
          statement: "A resource's improvement adds its full bonus: Pasture (+2 food, gated by Animal Husbandry) on Cattle and Sheep; Farm (+2 food) on Wheat; Mine (+2 production, gated by Mining) on Stone.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A Pasture on Cattle stacks to five food",
              body: "Given Wes has completed Animal Husbandry and a worker builds a Pasture on a Cattle grassland tile
When the tile is worked
Then it yields 5 food (2 terrain + 1 resource + 2 Pasture)"
            },
            %{
              kind: "failure path",
              title: "Pasture needs Animal Husbandry first",
              body: "Given Wes has not completed Animal Husbandry
When he selects a worker on a Cattle tile
Then Pasture is not an available improvement"
            }
          ]
        },
        %{
          statement: "Resources are visible on the board from the start — no reveal technology is required to see them.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Resources are visible from the first look",
              body: "Given a fresh player who has researched nothing
When they view explored terrain containing resources
Then the resource icons are shown on those tiles"
            }
          ]
        },
        %{
          statement: "A city prefers to work its resource tiles, since a resource tile scores higher than a plain one of the same terrain.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A city works its resource tile first",
              body: "Given a city with a Cattle grassland tile and a plain grassland tile both available to work
When it auto-assigns a citizen
Then it works the Cattle tile before the plain one"
            }
          ]
        },
        %{
          statement: "Resource density is a per-world setting chosen at world creation (a slider); it scales how many eligible tiles receive a resource, defaulting to about 1 per 12 land tiles.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A resource-rich world has more than a sparse one",
              body: "Given two worlds created from the same seed, one with a high resource-density setting and one with a low one
When their resource tiles are counted
Then the high-density world has proportionally more resource tiles than the low-density one"
            }
          ]
        },
        %{
          statement: "At the standard (default) density, resources occupy about 7% of land tiles — roughly one resource per 12 to 15 land tiles.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A standard world is sparsely sprinkled, not carpeted",
              body: "Given a world generated at the standard default density with 210 land tiles
When resource placement runs
Then about 14 to 17 land tiles carry a resource (roughly 7%, one per 12 to 15 tiles)
And the large majority of land tiles carry no resource at all"
            },
            %{
              kind: "happy path",
              title: "The default no longer feels like resources everywhere",
              body: "Given a world generated at the standard default density
When Wes scans the board around his starting city
Then he sees only a few resource tiles nearby rather than a resource on almost every workable tile
And which tiles get resources is unchanged for the same seed (deterministic placement is preserved)"
            }
          ]
        },
        %{
          statement: "The per-world density slider still spans sparser-to-richer worlds, but its default sits at the sparse Civ-like setting rather than the old resource-heavy default.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The slider still reaches richer worlds from a sparse default",
              body: "Given the density slider left at its default position
Then the world is generated at the sparse ~7%-of-land target
When the player raises the slider toward its maximum and regenerates
Then noticeably more land tiles carry resources than at the default
And lowering the slider toward its minimum produces an even sparser world"
            }
          ]
        }
      ],
      questions: [
        %{body: "Exact resource set: animal-only (Cattle + Sheep, the minimum for Animal Husbandry), the four-resource default (Cattle/Sheep/Wheat/Stone — Wheat/Stone reuse Farm/Mine for free), or also add Deer? Note: our tech tree has Pasture but no Camp, so Deer either defers or diverges from Civ by using a Pasture.", status: :resolved, resolution: nil},
        %{body: "Placement density — the research suggests ~1 resource per 12 land tiles (roughly 55% food / 45% production). Confirm that target, and decide whether a resource may sit on a tile that later becomes a city center (recommended: allow it; the city-center yield floor still applies).", status: :resolved, resolution: nil},
        %{body: "Density re-tuning is a build-phase follow-up: this lower default (~7% of land, one resource per 12-15 tiles) requires changing the density constants in code AND updating the existing 905 density spex, which currently encode the old higher default. Confirm the exact default target within the 12-15 band and the per-resource split (recommended ~55% food: Cattle/Sheep/Wheat, ~45% production: Stone).", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 906,
    status: :in_progress,
    title: "Unit Attacks City",
    description:
      "As a player, I want to besiege and capture an enemy player's city with my military units, so that I can expand my territory and bring rival players under my rule.

Source: .code_my_spec/stories/more_stories.md §6.2. First player-vs-player combat in the game (the Stone Age deliberately excluded PvP; this opens it). A military unit or lord adjacent to a hostile PLAYER city can attack it.

Locked design (see .code_my_spec/knowledge/feudal_vassalage_design.md):
- SIEGE & GRIND, Civ-style — cities are TOUGH. Defensive strength = base (20 + 5·size) + garrison bonus (895); the city has HP and counter-attacks; bringing it down takes multiple turns, so the owner and allies can react or relieve the siege. Conquest is a campaign, not a click.
- CAPTURE MOMENT: zeroing the city's HP breaks it, but the attacker must then MOVE A UNIT ONTO THE CITY TILE to occupy it (Civ-style). No range-flip — you commit and hold a body.
- FALLEN GARRISON: on capture the CONQUEROR CHOOSES to execute the defenders or let them flee, and the choice carries a small HONOR consequence (mercy is honorable; the sword costs Honor).
- The captured city becomes \"occupied\": the original owner keeps it and, in peacetime, keeps running it (build/grow/work tiles) while the captor draws tribute/levies. Wartime/revolt control may differ (design flagged). This owner-runs-it-lord-skims rule is what makes the loser a vassal, not a corpse.
- Capture fires the last-free-city check that drives Automatic Vassalization (907).

Builds on Unit Combat (891), City Defense and Garrison (895), turn/movement (874/875). Three Amigos to decide: in-progress production on capture, whether razing is an option, the exact Honor deltas for execute-vs-release, and how \"occupied\" renders on the globe.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Adjacent warrior attacks a rival player's city", verified: false},
      %{description: "Non-adjacent unit cannot attack the city", verified: false},
      %{description: "A civilian unit cannot besiege a city", verified: false},
      %{description: "Size-4 city computes defense 40 and counter-attacks", verified: false},
      %{description: "Garrison bonus raises the size-4 city's defense above 40", verified: false},
      %{description: "Repeated assaults grind a city down to broken over several turns", verified: false},
      %{description: "Owner relief heals the siege before HP hits zero", verified: false},
      %{description: "Moving a unit onto a broken city occupies it", verified: false},
      %{description: "Broken city left un-entered is not captured and can be regarrisoned", verified: false},
      %{description: "Merciful conqueror releases the garrison", verified: false},
      %{description: "Conqueror executes the garrison and loses Honor", verified: false},
      %{description: "Occupied city keeps being run by its original owner in peacetime", verified: false},
      %{description: "Occupying a non-last city leaves the owner free", verified: false},
      %{description: "Occupying the owner's last free city fires the vassalization trigger", verified: false}
    ],
    qa: %{final: :pass, attempts: 3, history: [:fail, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Only a military unit or lord adjacent to a hostile player-owned city may attack that city.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Adjacent warrior attacks a rival player's city",
              body: "Given Wes owns a warrior on a hex directly adjacent to rival player Mara's city
And Mara's city is hostile to Wes
When Wes orders the warrior to attack the city
Then the assault is allowed and the siege begins"
            },
            %{
              kind: "failure path",
              title: "Non-adjacent unit cannot attack the city",
              body: "Given Wes owns a warrior two hexes away from Mara's city
When Wes orders the warrior to attack the city
Then the attack is rejected because the unit is not adjacent
And no siege begins"
            },
            %{
              kind: "failure path",
              title: "A civilian unit cannot besiege a city",
              body: "Given Wes owns a settler (non-military unit) adjacent to Mara's city
When Wes tries to order the settler to attack the city
Then the attack option is unavailable because the settler is not a military unit"
            }
          ]
        },
        %{
          statement: "A besieged city defends with strength = base (20 + 5·size) + garrison bonus, and counter-attacks the besieging unit each turn.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Size-4 city computes defense 40 and counter-attacks",
              body: "Given Mara's city is size 4 with no garrison bonus
When Wes's warrior assaults it
Then the city defends with strength 40 (base 20 + 5·4)
And the city counter-attacks Wes's warrior, dealing damage to the besieger that turn"
            },
            %{
              kind: "happy path",
              title: "Garrison bonus raises the size-4 city's defense above 40",
              body: "Given Mara's size-4 city has a garrison granting a +10 defense bonus (895)
When Wes's warrior assaults it
Then the city defends with strength 50 (base 40 + garrison 10)"
            }
          ]
        },
        %{
          statement: "A city has hit points that assaults chip away over multiple turns; the city is broken only when its HP reaches zero.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Repeated assaults grind a city down to broken over several turns",
              body: "Given Mara's city has 100 HP and each of Wes's assaults removes about 20 HP
When Wes assaults the city on five successive turns
Then the city HP drops 100 → 80 → 60 → 40 → 20 → 0 over the turns
And the city is marked broken only when HP reaches 0"
            },
            %{
              kind: "happy path",
              title: "Owner relief heals the siege before HP hits zero",
              body: "Given Mara's city is down to 20 HP from Wes's siege
When Mara moves a relief army in and destroys the besieging warrior before the next assault
Then the city is not broken and its HP recovers over subsequent turns"
            }
          ]
        },
        %{
          statement: "A broken city is not captured until the attacker moves a unit onto the city tile; there is no range-flip.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Moving a unit onto a broken city occupies it",
              body: "Given Mara's city is broken at 0 HP and Wes has a warrior adjacent to it
When Wes moves the warrior onto the city tile
Then the city becomes occupied by Wes"
            },
            %{
              kind: "failure path",
              title: "Broken city left un-entered is not captured and can be regarrisoned",
              body: "Given Mara's city is broken at 0 HP but Wes never moves a unit onto the tile
And Wes's besieging warrior is then killed by a counter-attack
When the next turn resolves
Then the city remains Mara's (not captured)
And Mara can move a unit in to regarrison and begin recovering the city"
            }
          ]
        },
        %{
          statement: "On occupying a city the conqueror chooses to execute or release the fallen garrison; executing costs a small Honor delta while releasing is neutral-to-positive.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Merciful conqueror releases the garrison",
              body: "Given Wes has just occupied Mara's city and a fallen garrison remains
When Wes chooses to let the garrison flee
Then the garrison is released
And Wes's Honor is unchanged or slightly improved"
            },
            %{
              kind: "failure path",
              title: "Conqueror executes the garrison and loses Honor",
              body: "Given Wes has just occupied Mara's city and a fallen garrison remains
When Wes chooses to execute the garrison
Then the garrison is destroyed
And Wes's Honor drops by a small amount"
            }
          ]
        },
        %{
          statement: "An occupied city stays on its original owner's roster and, in peacetime, the owner keeps running it while the captor draws tribute and levies.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Occupied city keeps being run by its original owner in peacetime",
              body: "Given Wes has occupied Mara's city and peace holds
Then the city stays on Mara's city roster
And Mara continues to choose its production, growth, and worked tiles
And Wes draws tribute and levies from it rather than controlling it directly"
            }
          ]
        },
        %{
          statement: "Occupying a city fires the last-free-city check that can trigger automatic vassalization.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Occupying a non-last city leaves the owner free",
              body: "Given Mara owns two cities, both free
When Wes occupies one of them
Then the last-free-city check runs and finds Mara still has one free city
And no vassalization is triggered"
            },
            %{
              kind: "happy path",
              title: "Occupying the owner's last free city fires the vassalization trigger",
              body: "Given Mara has only one free city left
When Wes occupies it
Then the last-free-city check runs and finds Mara has zero free cities
And it hands off to the automatic vassalization flow (907)"
            }
          ]
        }
      ],
      questions: [
        %{body: "What happens to a captured city's in-progress production (the current build order and accumulated production) at the moment of occupation — is it preserved, cancelled, or refunded?", status: :open, resolution: nil},
        %{body: "Is razing (destroying) a captured city an allowed option, or is occupation the only outcome? If razing exists, what are its Honor and vassalization consequences?", status: :open, resolution: nil},
        %{body: "What are the exact numeric Honor deltas for executing versus releasing the fallen garrison?", status: :open, resolution: nil},
        %{body: "How does an \"occupied\" city render on the globe (owner colour vs captor colour, an occupation marker, siege state) so both players can read the situation?", status: :open, resolution: nil},
        %{body: "During wartime or active revolt, how does control of an occupied city differ from the peacetime \"owner runs it, lord skims\" rule (e.g. lord draws production/levies, or the city becomes contested)?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 907,
    status: :in_progress,
    title: "Automatic Vassalization",
    description:
      "As a player who captures another player's last free city, I want that player to become my sworn vassal and keep playing under my rule, so that I profit from their continued existence instead of eliminating them.

Source: .code_my_spec/stories/more_stories.md §7.1. The core feudal pivot: conquest produces a subordinate, not an elimination. Persistent/endless world — there is NO game-victory; a vassal keeps playing forever with their own ambitions.

Locked design (see .code_my_spec/knowledge/feudal_vassalage_design.md):
- Trigger: a capture (906) that leaves the defeated player with NO free (non-occupied) cities makes them the captor's vassal.
- OATH SCREEN (\"Terms of Oath\") at the moment of subjugation: the vassal secretly picks a HIDDEN AGENDA — a personal ongoing ambition (e.g. Restore / Usurp / Kingmaker / Merchant Prince) — reframing defeat as a new game. Depth may phase in, but the schema carries it from day one.
- Creates the VASSALAGE relationship (player→player) whose schema, from the start, carries forward-looking fields even if not all are exercised yet: tribute rate (default 25%), Oath Strain / liberty pressure (0-100), Honor ledger hooks, the hidden agenda, and the reciprocal CONTRACT terms (what the lord owes — protection, spoils, autonomy). This avoids a schema rebuild when the rebellion/reciprocity batch lands.
- Both players notified; vassal UI shows \"Sworn to X\"; lord gains a \"Vassals\" list. The vassal keeps playing fully (move, build, grow, research).

Engine-enforced with Honor stakes: the oath is a real contract; breaking it is allowed but publicly brands the breaker. Depends on Unit Attacks City (906). Three Amigos to decide: the relationship schema shape, precise \"last free city\" definition, the Hidden Agenda option set for v1, and the Vassals/Sworn-to UI surfacing.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Losing the last free city triggers vassalization", verified: false},
      %{description: "Losing one of several cities does not create vassalage", verified: false},
      %{description: "Vassal secretly chooses a Hidden Agenda on the Oath screen", verified: false},
      %{description: "New vassalage record is created with default forward-looking fields", verified: false},
      %{description: "Both players are notified and the relationship surfaces in each UI", verified: false},
      %{description: "Vassal keeps playing normally after subjugation", verified: false},
      %{description: "A player already holding an occupied city becomes a vassal when their last free city falls", verified: false}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A capture that leaves the defeated player with zero free (non-occupied) cities makes them the captor's vassal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Losing the last free city triggers vassalization",
              body: "Given Mara has exactly one free city and no other cities
When Wes occupies that city
Then Mara has zero free cities
And Mara becomes Wes's vassal"
            },
            %{
              kind: "happy path",
              title: "A player already holding an occupied city becomes a vassal when their last free city falls",
              body: "Given Mara has two cities: one already occupied by Wes and one still free
When Wes occupies the remaining free city
Then Mara has zero free cities (the occupied one does not count as free)
And Mara becomes Wes's vassal"
            }
          ]
        },
        %{
          statement: "A capture that leaves the defeated player with at least one free city does not create vassalage.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Losing one of several cities does not create vassalage",
              body: "Given Mara has three cities, all free
When Wes occupies one of them
Then Mara still has two free cities
And no vassalage relationship is created"
            }
          ]
        },
        %{
          statement: "At subjugation the vassal secretly picks one Hidden Agenda from the four options (Restore, Usurp, Kingmaker, Merchant Prince) on the Terms of Oath screen.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Vassal secretly chooses a Hidden Agenda on the Oath screen",
              body: "Given Mara has just lost her last free city and the Terms of Oath screen appears
When Mara selects \"Usurp\" from the four agendas (Restore, Usurp, Kingmaker, Merchant Prince)
Then the agenda is stored on Mara's vassalage relationship
And Wes (the lord) is not shown which agenda Mara chose"
            }
          ]
        },
        %{
          statement: "Vassalization creates a Vassalage relationship (player→player) carrying from day one: tribute rate (default 25%), Oath Strain (0-100), Honor ledger hooks, the hidden agenda, and reciprocal contract terms.",
          scenarios: [
            %{
              kind: "happy path",
              title: "New vassalage record is created with default forward-looking fields",
              body: "Given Mara becomes Wes's vassal
When the vassalage relationship is created
Then it records lord Wes and vassal Mara
And tribute rate defaults to 25%
And Oath Strain is 0
And it carries Honor ledger hooks, the chosen hidden agenda, and reciprocal contract terms (protection, spoils, autonomy) even though those are not yet exercised"
            }
          ]
        },
        %{
          statement: "On vassalization both players are notified; the vassal's UI shows \"Sworn to X\" and the lord gains a Vassals list entry.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Both players are notified and the relationship surfaces in each UI",
              body: "Given Mara becomes Wes's vassal
Then both Mara and Wes receive a notification of the new oath
And Mara's UI shows \"Sworn to Wes\"
And Wes's Vassals list gains an entry for Mara"
            }
          ]
        },
        %{
          statement: "A vassal keeps playing fully (move, build, grow, research) — the world is persistent and endless with no game-victory or elimination.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Vassal keeps playing normally after subjugation",
              body: "Given Mara is now Wes's vassal
When Mara takes her next turn
Then Mara can still move units, build in her city, grow it, and research
And Mara is not eliminated and the game does not end for anyone"
            }
          ]
        }
      ],
      questions: [
        %{body: "What exactly counts as a \"free city\" for the last-free-city test — does a city under active siege but not yet occupied count as free, and do edge states like a starving/size-0 city or a city mid-founding count?", status: :open, resolution: nil},
        %{body: "How is simultaneous multi-capture handled — if a single turn-boundary resolution occupies a player's last two free cities at once, or takes the last free cities of two different players in the same tick, how is the trigger ordered and attributed?", status: :open, resolution: nil},
        %{body: "What is the exact Vassalage relationship schema shape — field names, types, defaults, and how the reciprocal contract terms (protection, spoils, autonomy) and the hidden agenda are represented?", status: :open, resolution: nil},
        %{body: "What are the Vassals-list and \"Sworn to X\" UI specifics — where each surfaces, what fields are shown, and confirmation that the lord never sees the vassal's chosen hidden agenda?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 908,
    status: :in_progress,
    title: "Tribute Payments",
    description:
      "As a lord, I want to set the tribute my vassals owe — gold and military levies — and collect it each turn, so that I can tune extraction against loyalty and profit from my conquests while keeping vassals in the game.

Source: .code_my_spec/stories/more_stories.md §7.2, extended to \"gold + military levies\" with a lord-set, adjustable rate.

Locked design (see .code_my_spec/knowledge/feudal_vassalage_design.md):
- TRIBUTE RATE IS A LORD-SET, PER-VASSAL, ADJUSTABLE LEVER (not a fixed 25%). It is the core happiness/retention dial: a high cut = more income but rising Oath Strain; a low cut = a contented, stable vassal. Default starting rate ~25%. The lord sets/changes it from the Vassals panel; the vassal sees the current rate.
- GOLD TRIBUTE: each turn boundary, tribute = vassal gross per-turn gold income × the lord's set rate, transferred vassal→lord; both see a GOLD LOG entry. Insufficient gold → debt (negative balance allowed). Greed should be self-limiting so lords cannot snowball infinitely (aggregate strain rises with more/greedier vassals — full curve in the next batch).
- MILITARY LEVIES — CALL TO ARMS: the lord issues a call to a war; the vassal must send units or REFUSE. Refusal spikes Oath Strain and dings the Honor ledger (a publicly-legible broken obligation). The vassal keeps command of their army but owes the service; a refused call is first-class drama.
- Runs inside the per-world turn pipeline (874) and must scale to many concurrent vassal relationships per world.

Depends on Automatic Vassalization (907). Three Amigos to decide: the exact gross-income basis, debt handling/consequences, how a call to arms is issued/answered/refused and what \"must send units\" concretely requires, and the Vassals-panel rate control + gold-log + levy-call UI.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Lord raises a vassal's tribute rate from the Vassals panel", verified: false},
      %{description: "Vassal earning 12 gold/turn at 25% pays 3 gold tribute", verified: false},
      %{description: "A raised rate is applied on the next turn's tribute", verified: false},
      %{description: "Vassal with an empty treasury goes into debt paying tribute", verified: false},
      %{description: "Vassal answers a call to arms and keeps command of the units sent", verified: false},
      %{description: "Vassal refuses the call to arms and takes strain and Honor hits", verified: false},
      %{description: "Many vassal tributes resolve in one turn tick", verified: false}
    ],
    qa: %{final: :pass, attempts: 3, history: [:fail, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Each vassal's tribute rate is a lord-set, per-vassal, adjustable lever (default ~25%) that the lord changes from the Vassals panel and the vassal can see.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Lord raises a vassal's tribute rate from the Vassals panel",
              body: "Given Mara is Wes's vassal at the default 25% tribute rate
When Wes opens the Vassals panel and changes Mara's rate to 40%
Then Mara's tribute rate is stored as 40%
And Mara can see her current rate is 40%"
            }
          ]
        },
        %{
          statement: "Each turn boundary, gold tribute = vassal gross per-turn gold income × the rate, transferred vassal→lord, with a gold-log entry for both.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Vassal earning 12 gold/turn at 25% pays 3 gold tribute",
              body: "Given Mara's gross per-turn gold income is 12 and her tribute rate is 25%
When the turn boundary resolves
Then 3 gold transfers from Mara to Wes
And both Mara and Wes get a gold-log entry recording the 3-gold tribute"
            },
            %{
              kind: "happy path",
              title: "A raised rate is applied on the next turn's tribute",
              body: "Given Wes has just raised Mara's rate to 50% and Mara's gross income is 12
When the next turn boundary resolves
Then 6 gold transfers from Mara to Wes
And the gold log records 6 gold at the 50% rate"
            }
          ]
        },
        %{
          statement: "When the vassal cannot cover the tribute, the shortfall becomes debt and a negative gold balance is allowed.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Vassal with an empty treasury goes into debt paying tribute",
              body: "Given Mara owes 3 gold tribute this turn but her treasury holds 0 gold
When the turn boundary resolves
Then Mara's balance goes to -3 (negative balance allowed)
And Wes still receives the 3 gold and the log records the transfer"
            }
          ]
        },
        %{
          statement: "The lord can issue a call to arms to a war; the vassal must send units or refuse, and keeps command of any units sent.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Vassal answers a call to arms and keeps command of the units sent",
              body: "Given Wes issues a call to arms to Mara for his war
When Mara answers by committing 2 warriors to the war
Then the call is satisfied
And Mara still commands those 2 warriors rather than handing control to Wes"
            }
          ]
        },
        %{
          statement: "Refusing a call to arms spikes the vassal's Oath Strain and dings their Honor ledger as a publicly-legible broken obligation.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Vassal refuses the call to arms and takes strain and Honor hits",
              body: "Given Wes has issued a call to arms to Mara
When Mara refuses to send any units
Then Mara's Oath Strain rises
And Mara's Honor ledger takes a hit recorded as a broken obligation visible to others"
            }
          ]
        },
        %{
          statement: "Tribute collection and levy calls run inside the per-world turn pipeline and scale to many concurrent vassal relationships.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Many vassal tributes resolve in one turn tick",
              body: "Given a world has 30 active vassalage relationships across several lords
When a single turn boundary resolves
Then every vassal's gold tribute is computed, transferred, and logged in that tick
And the turn pipeline completes without special-casing any one relationship"
            }
          ]
        }
      ],
      questions: [
        %{body: "What exactly is the \"gross per-turn gold income\" basis the rate applies to — city gold yield only, or also trade/other sources, and is it measured before or after the vassal's own upkeep/expenses?", status: :open, resolution: nil},
        %{body: "What are the consequences of sustained debt (a persistent negative balance) — interest, extra Oath Strain, capped growth, asset seizure, or none for now?", status: :open, resolution: nil},
        %{body: "What does \"must send units\" concretely require on a call to arms — how many units and which types, where they must go, for how long, and what deadline the vassal has to answer before it counts as a refusal?", status: :open, resolution: nil},
        %{body: "What are the UI specifics for the Vassals-panel rate control, the shared gold log, and the call-to-arms issue/answer/refuse flow?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 909,
    status: :in_progress,
    title: "Gold Bank and Upgrades",
    description:
      "As a player, I want the gold I earn while away to fill an upgradeable bank rather than pile up infinitely, so that there is a reason to return (or be tended) and my economy has a meaningful storage decision.

Source: engagement-mechanic design (2026-07-18), see .code_my_spec/knowledge/feudal_vassalage_design.md.

Locked design:
- GOLD BANK with a CAPACITY CAP equal to the bank's size. Gold earned while the player is OFFLINE accrues into the bank up to its cap; once full, accrual STOPS (no gold is lost, but idle time is wasted until collected) — the reason to return or be tended by a steward.
- While the player is LOGGED IN, gold flows to their usable treasury directly; while OFFLINE it accrues into the capped bank. COLLECT = a click that sweeps bank -> treasury (a deliberate engagement tap). A variant where gold ALWAYS lands in the bank and must be clicked into the treasury is an acceptable tuning if we want the collect-tap every session.
- UPGRADE THE BANK: the player can raise the cap (costs gold/production) — bigger bank = more offline earnings retained. A real economy decision.
- Foundation for Feudal Stewardship (910): a lord/fellow vassals can collect an offline player's bank FOR them (all to the owner).

Extends the existing gold/economy and city-yield systems. Three Amigos to decide: bank size tiers + upgrade cost curve, exactly which gold accrues to the bank, the online-treasury vs always-bank tap model, and the collect UI.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Offline earnings accrue into the bank below the cap", verified: false},
      %{description: "Bank holds at the cap and wastes the overflow", verified: false},
      %{description: "Logged-in earnings land in the treasury, not the bank", verified: false},
      %{description: "Collect sweeps the banked gold into the treasury", verified: false},
      %{description: "Upgrading the bank raises the cap", verified: false},
      %{description: "Upgrade is blocked when the player cannot afford it", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Each player has a gold bank with a capacity cap equal to the bank's size, and while the player is offline their earned gold accrues into the bank up to that cap.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Offline earnings accrue into the bank below the cap",
              body: "Given Wes has a bank with a 50-gold cap and an empty bank
And Wes is offline
When his cities yield 10 gold on each of 3 turns while he is away
Then his bank holds 30 gold
And his usable treasury is unchanged"
            }
          ]
        },
        %{
          statement: "Once the offline bank reaches its cap, accrual stops — no gold is lost, but further idle earnings are wasted until the bank is collected.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Bank holds at the cap and wastes the overflow",
              body: "Given Wes has a 50-gold-cap bank already holding 45 gold
And Wes is offline
When his cities yield another 20 gold across the next turns while he is away
Then his bank holds exactly 50 gold
And the 15 gold earned past the cap is not banked and is simply wasted idle time
And no gold already in the bank is lost"
            }
          ]
        },
        %{
          statement: "While the player is logged in, earned gold flows directly to their usable treasury rather than into the bank.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Logged-in earnings land in the treasury, not the bank",
              body: "Given Wes is logged in with a treasury of 100 gold and an empty bank
When his cities yield 10 gold on the next turn
Then his treasury holds 110 gold
And his bank is still empty"
            }
          ]
        },
        %{
          statement: "Collect is a single action that sweeps the bank's entire balance into the treasury and leaves the bank empty.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Collect sweeps the banked gold into the treasury",
              body: "Given Wes returns to a bank holding 30 gold and a treasury of 100 gold
When he clicks Collect
Then his treasury holds 130 gold
And his bank is empty
And accrual for the current session now flows to the treasury"
            }
          ]
        },
        %{
          statement: "A player can upgrade the bank to raise its cap for a cost, and a larger cap retains more offline earnings.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Upgrading the bank raises the cap",
              body: "Given Wes has a 50-gold-cap bank and can afford the upgrade cost
When he purchases the next bank tier
Then the upgrade cost is deducted
And his bank cap rises to the new tier (e.g. 100)
And a subsequent offline stretch now accrues up to 100 gold instead of 50"
            },
            %{
              kind: "failure path",
              title: "Upgrade is blocked when the player cannot afford it",
              body: "Given Wes has a 50-gold-cap bank and cannot afford the next tier's cost
When he attempts to purchase the upgrade
Then the upgrade is refused
And no cost is deducted
And his bank cap stays at 50"
            }
          ]
        }
      ],
      questions: [
        %{body: "What are the bank size tiers and the upgrade cost curve (starting cap, per-tier cap increments, and cost per tier)?", status: :open, resolution: nil},
        %{body: "Exactly which gold sources accrue to the bank while offline — gross city yields only, or does it include tribute received and other one-off gold?", status: :open, resolution: nil},
        %{body: "Do we ship the online-treasury-direct model or the always-bank/collect-every-session variant? This changes whether a logged-in player also has a collect tap.", status: :open, resolution: nil},
        %{body: "What is the collect UI — where does the bank/collect button live, and does it show fill percentage and a full/capped warning?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 910,
    status: :in_progress,
    title: "Feudal Stewardship",
    description:
      "As a lord, fellow vassal, OR ally, I want to tend a household or allied member's realm while they are offline — collecting their bank, managing their production, and defending them if attacked — so that being sworn into a household OR bound in an alliance is a genuine benefit and no one gets farmed while away.

Source: engagement-mechanic design (2026-07-18), see .code_my_spec/knowledge/feudal_vassalage_design.md. The upside half of vassalage AND of alliance: your people cover for you.

Locked design:
- WHO STEWARDS WHOM: while a player is OFFLINE they can be stewarded by (a) their LORD, (b) their FELLOW VASSALS of the same lord, and (c) their ALLIES (the existing alliance relationship from stories 899/901). Feudal stewardship keeps the asymmetry that lords are NEVER stewarded by their vassals (protection flows down). ALLIANCE stewardship is SYMMETRIC/mutual — allied peers can each steward the other.
- BANK COLLECTION: a steward sweeps the offline player's Gold Bank (909) — ALL to the OWNER's treasury (pure stewardship; the steward gets nothing; tribute still skims separately). Keeps the offline player's economy from capping out.
- PRODUCTION STEWARDSHIP: a steward may set the offline player's production queue, CONSTRUCTIVE-ONLY — from a safe whitelist of economic/defensive builds. No disbanding, no cancel-griefing, no nonsense.
- EMERGENCY DEFENSE: normally stewards CANNOT move the offline player's units. BUT if the offline player is UNDER ATTACK, a steward may command their units to DEFEND — defensive orders only, active only while under attack; never to launch aggression or march the army off.
- ANTI-SABOTAGE: every steward action is LOGGED for the owner to review on return; provable sabotage dings the steward's HONOR (engine-enforced). Constructive-only + Honor stakes keep stewardship a benefit, not a grief vector.

Depends on Automatic Vassalization (907), the alliance relationship (899/901), Gold Bank (909), and the production-queue (879) / unit-combat (891) systems. Three Amigos to decide: the production whitelist, the exact \"under attack\" trigger and bounds of emergency defensive control, symmetric-vs-asymmetric edge cases, the steward-action log/undo UI, and Honor deltas for sabotage.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Lord and fellow vassal can steward an offline household member", verified: false},
      %{description: "A vassal cannot steward their own lord", verified: false},
      %{description: "Allied peers can steward each other symmetrically", verified: false},
      %{description: "Steward sweeps the offline bank entirely to the owner", verified: false},
      %{description: "Steward queues a whitelisted constructive build", verified: false},
      %{description: "Steward cannot disband a unit or cancel an in-progress build", verified: false},
      %{description: "Steward cannot move units when the owner is not under attack", verified: false},
      %{description: "Ally issues a defensive order while the offline owner is under attack", verified: false},
      %{description: "Steward cannot use the emergency window to march the army off or attack", verified: false},
      %{description: "Owner reviews a full steward-action log on return", verified: false},
      %{description: "Provable sabotage dings the steward's Honor", verified: false}
    ],
    qa: %{final: :pass, attempts: 2, history: [:partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "While a player is offline they may be stewarded by their lord and by their fellow vassals of the same lord.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Lord and fellow vassal can steward an offline household member",
              body: "Given Wes is a vassal sworn to Lord Ada, and Bo is another vassal also sworn to Ada
And Wes is offline
When Lord Ada opens Wes's realm, and separately fellow-vassal Bo opens Wes's realm
Then both are offered the steward controls over Wes's realm
And a player with no household tie to Wes is offered nothing"
            }
          ]
        },
        %{
          statement: "A lord is never stewarded by their own vassals — feudal stewardship flows down the household, not up.",
          scenarios: [
            %{
              kind: "failure path",
              title: "A vassal cannot steward their own lord",
              body: "Given Wes is a vassal sworn to Lord Ada
And Lord Ada is offline
When Wes tries to steward Ada's realm
Then no steward controls are offered
And the attempt is refused because protection flows down the household, not up"
            }
          ]
        },
        %{
          statement: "An ally may steward an offline ally, and alliance stewardship is symmetric — each allied peer can steward the other with the same powers a household steward has.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Allied peers can steward each other symmetrically",
              body: "Given Wes and Kai are in an alliance (relationship from stories 899/901) with no lord/vassal tie between them
When Kai goes offline, Wes is offered the full steward controls over Kai's realm
And later when Wes goes offline, Kai is offered the full steward controls over Wes's realm
Then alliance stewardship works in both directions with the same powers a household steward has"
            }
          ]
        },
        %{
          statement: "A steward collecting the offline player's Gold Bank sweeps all of it into the owner's treasury; the steward receives nothing and tribute still skims separately.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Steward sweeps the offline bank entirely to the owner",
              body: "Given offline Wes's Gold Bank holds 30 gold and his treasury holds 100 gold
And fellow-vassal Bo is stewarding Wes
When Bo collects Wes's bank
Then all 30 gold lands in Wes's treasury, which now holds 130
And Wes's bank is empty
And Bo receives nothing from the sweep, while the lord's per-turn tribute still skims separately"
            }
          ]
        },
        %{
          statement: "A steward may set the offline player's production queue only from a constructive whitelist of economic and defensive builds — no disbanding, cancelling, or griefing.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Steward queues a whitelisted constructive build",
              body: "Given offline Wes has an idle production queue in his city
And fellow-vassal Bo is stewarding Wes
When Bo queues a granary (an economic/defensive whitelist build)
Then the granary is added to Wes's production queue
And the action is recorded in Wes's steward-action log"
            },
            %{
              kind: "failure path",
              title: "Steward cannot disband a unit or cancel an in-progress build",
              body: "Given offline Wes has a warrior and an in-progress wall in his city
And fellow-vassal Bo is stewarding Wes
When Bo tries to disband the warrior or cancel the wall
Then both actions are blocked as outside the constructive whitelist
And Wes's units and existing queue are unchanged"
            }
          ]
        },
        %{
          statement: "Stewards cannot move the offline player's units under normal conditions.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Steward cannot move units when the owner is not under attack",
              body: "Given offline Wes is not under attack
And fellow-vassal Bo is stewarding Wes
When Bo tries to move Wes's warrior to an adjacent hex
Then the move is blocked
And Wes's units stay where they are"
            }
          ]
        },
        %{
          statement: "While the offline player is under attack, a steward may issue defensive-only orders to that player's units — active only while under attack, never to launch aggression or march the army off.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Ally issues a defensive order while the offline owner is under attack",
              body: "Given offline Kai's city is under attack by a raider
And Kai's ally Wes is stewarding Kai
When Wes orders Kai's nearby units to fortify and garrison the threatened city
Then the defensive orders are accepted while the attack is active
And the orders are recorded in Kai's steward-action log"
            },
            %{
              kind: "failure path",
              title: "Steward cannot use the emergency window to march the army off or attack",
              body: "Given offline Wes's city is under attack
And fellow-vassal Bo is stewarding Wes
When Bo tries to march Wes's army off to attack a neutral city instead of defending
Then the aggressive/marching-off order is blocked
And only defensive orders around the threatened city are permitted
And once the attack ends the emergency unit control lapses"
            }
          ]
        },
        %{
          statement: "Every steward action is logged for the owner to review on return, and provable sabotage dings the steward's Honor.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Owner reviews a full steward-action log on return",
              body: "Given while Wes was offline his stewards collected his bank, queued a granary, and issued a defensive order during an attack
When Wes logs back in
Then his steward-action log lists each action with who did it and when
And nothing a steward did is hidden from the owner"
            },
            %{
              kind: "failure path",
              title: "Provable sabotage dings the steward's Honor",
              body: "Given fellow-vassal Bo took a steward action against Wes that is provable sabotage
When the sabotage is established from the logged action
Then Bo's Honor is dinged by the engine
And the event is visible to Wes in his steward-action log"
            }
          ]
        }
      ],
      questions: [
        %{body: "What exactly is on the constructive production whitelist a steward may queue (which economic/defensive builds are in, and are any units allowed)?", status: :open, resolution: nil},
        %{body: "What is the precise \"under attack\" trigger that opens the emergency defensive window, and what are the bounds of defensive control (which order types count as defensive, how far units may move, and when exactly the window closes)?", status: :open, resolution: nil},
        %{body: "What is the steward-action log/undo UI — where it lives, and whether the owner can undo or roll back a steward action on return.", status: :open, resolution: nil},
        %{body: "What are the Honor deltas for provable sabotage, and how is \"provable sabotage\" adjudicated (automatic engine detection vs. owner report)?", status: :open, resolution: nil},
        %{body: "When multiple eligible stewards (lord, fellow vassals, allies) act on the same offline player concurrently, how are conflicting production/defensive orders resolved?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 911,
    status: :in_progress,
    title: "Strategic Resources: Bronze for Bronze Spearmen",
    description:
      "As a player, I want certain military units to require a strategic resource, so that map control matters and I must secure the right terrain before I can field bronze-age soldiers.

Source: playtest change (issue 3013c09a). Introduces the first STRATEGIC resource, a Civ 6-style unit-gating mechanic layered on top of the bonus-resource substrate (story 905). A strategic resource representing the metal behind bronze (proposed name: Copper; bronze is an alloy so the raw map resource reads better as Copper or Tin) is placed deterministically on the map on suitable terrain (Civ 6 puts Copper on Hills). Following Civ 6 convention where a tech reveals its strategic resource (Bronze Working reveals Iron in Civ 6), the resource is revealed by / after researching Bronze Working (story 902) — the same tech that unlocks the Bronze Spearman (story 903), so a player sees the resource exactly when it becomes relevant. A city can train the Bronze Spearman ONLY if it has access to the resource; a city without access sees the unit disabled in its production menu with a clear reason (\"Requires Copper\"). The UI surfaces the requirement on the unit and whether the city currently meets it.

Proposed ACCESS rule (Civ 6-grounded, simplified for MVP): a city has access when a Copper tile lies within that city's owned territory (worked or not). For the MVP this is a pure ACCESS GATE — having access lets the city train Bronze Spearmen freely, with no per-unit stockpile consumption (Civ 6's stockpile/consumption model is deferred). Whether the resource must be improved to count, whether access can be shared between cities / via connection, and whether it is consumed vs merely access-gating are open product-owner questions.

Depends on Tile Resources (story 905, the resource substrate and deterministic placement), the Stone Age Technology Tree (story 902, Bronze Working as the reveal tech), and Advancing to Bronze Age (story 903, the Bronze Spearman unit this gates). This is requirements only; per-resource yields, exact terrain, reveal timing, and the access definition are Three Amigos / product-owner decisions.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A city with Copper can queue a Bronze Spearman", verified: false},
      %{description: "A city without Copper cannot train the Spearman", verified: false},
      %{description: "Copper in the borders counts even when unworked", verified: false},
      %{description: "Copper appears once Bronze Working lands", verified: false},
      %{description: "The requirement is legible in the production menu", verified: false}
    ],
    qa: %{final: :pass, attempts: 3, history: [:partial, :partial, :pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A city can train the Bronze Spearman only if it has access to the bronze strategic resource (proposed: Copper).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A city with Copper can queue a Bronze Spearman",
              body: "Given the player has researched Bronze Working and entered the Bronze Age
And a city has a Copper tile within its owned territory
When the player opens that city's production menu
Then the Bronze Spearman can be selected and added to the production queue"
            },
            %{
              kind: "failure path",
              title: "A city without Copper cannot train the Spearman",
              body: "Given the player has entered the Bronze Age
And a city has no Copper tile within its owned territory
When the player opens that city's production menu
Then the Bronze Spearman is disabled and cannot be queued
And the entry shows a clear reason such as \"Requires Copper\""
            }
          ]
        },
        %{
          statement: "A city has access to the resource when a Copper tile lies within that city's owned territory, whether or not the tile is currently worked.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Copper in the borders counts even when unworked",
              body: "Given a city owns a tile carrying Copper but no citizen is working that tile
When the game checks whether the city has bronze access
Then the city is counted as having access
And the Bronze Spearman is available to that city"
            }
          ]
        },
        %{
          statement: "The bronze strategic resource is revealed on the map by researching Bronze Working.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Copper appears once Bronze Working lands",
              body: "Given Copper tiles exist on the map but the player has not researched Bronze Working
Then those Copper tiles are not shown as Copper to the player
When the player completes Bronze Working research
Then Copper tiles the player can see are revealed on the board
And the player can now tell which of their cities have bronze access"
            }
          ]
        },
        %{
          statement: "The Bronze Spearman's production entry shows its resource requirement and whether the city currently meets it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The requirement is legible in the production menu",
              body: "Given the Bronze Spearman is unlocked
When the player views it in a city that has Copper access
Then the entry shows the Copper requirement marked as met and the unit is enabled
And when the player views it in a city without Copper access
Then the entry shows the Copper requirement marked as unmet and the unit is disabled"
            }
          ]
        }
      ],
      questions: [
        %{body: "Resource name: what is the raw map resource called? Bronze is an alloy (copper + tin), so the mined resource reads better as Copper (recommended) or Tin. Confirm the name; the unit stays \"Bronze Spearman\".", status: :resolved, resolution: nil},
        %{body: "Reveal timing: is the resource hidden until Bronze Working is researched (Civ 6 convention, recommended, since the Spearman unlocks at the same tech) or always visible from the start like bonus resources? If hidden, does it reveal only inside explored/owned area or everywhere at once?", status: :resolved, resolution: nil},
        %{body: "Access definition: recommended MVP rule is \"a Copper tile within the city's owned territory, worked or not.\" Open forks: (a) must the Copper be improved (e.g. a Mine) to count, as Civ 6 requires? (b) can access be shared across all of a player's cities or via a road/trade connection, or is it strictly per-city? Confirm the exact rule.", status: :resolved, resolution: nil},
        %{body: "Consumed vs access-gated: MVP proposes a pure ACCESS GATE — having Copper lets a city train Bronze Spearmen freely with no per-unit stockpile consumption (Civ 6's stockpile model is deferred). Confirm no consumption for MVP, or decide each Spearman consumes a unit of a Copper stockpile.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 912,
    status: :in_progress,
    title: "City Gold Income",
    description:
      "As a player, I want each of my cities to generate gold every turn — a base amount that grows with the city and extra gold from certain worked tiles — so that I have a real, per-turn treasury income that tribute can tax and my bank can store while I am away.

Source: QA issue 589386f2 found the live game has NO per-turn gold income — cities only yield food/production (Game.Yields), and Game.Tribute reads its basis from a test-only seam (set_player_gold_income_for_test). Product owner decision (2026-07-18): cities generate gold Civ-style from a CITY BASE scaled by size PLUS gold-yielding worked tiles. Grounded in Civ VI gold conventions (see .code_my_spec/knowledge/civ6_resources.md) but kept simple and proportioned to this game's existing yields (size-1 base ~5 production/turn, ~2 science/pop, Stone Age size-4 cap).

Locked intent:
- CITY BASE GOLD/TURN scaled by size. Proposed default: 1 + floor(size/2) gold/turn (size 1 -> 1, size 2 -> 2, size 3 -> 2, size 4 -> 3). Modest, every city earns it. Exact formula is an open question for the PO.
- GOLD-YIELDING TILES add gold on top of the base when worked. Proposed default: worked Coast tiles yield +1 gold each (Civ commerce-from-the-sea convention); an optional Copper-style gold bonus resource (+2 gold) is a fork left as a question so we do not overload the tile-resource story (905). Kept modest so tribute numbers stay small (design's \"12 gold income\" examples).
- A city's per-turn gold income = base + summed worked-tile gold, recomputed each turn from current size and worked tiles.
- Each turn boundary, every city's gold income is added to the owner's TREASURY while online; while OFFLINE it accrues into the capped gold bank (story 909). The player's total per-turn gold income = the sum across their cities.
- This per-turn gold income REPLACES the test-only set_player_gold_income_for_test seam as tribute's real basis. Tribute (908) and the gold bank (909) will move to this real income in the code phase.

This is a foundational economy mechanic that UNDERPINS Tribute Payments (908) and the Gold Bank (909), and extends the city-yield / city-economy systems (879 City Production Queue, 880 City Growth). It is requirements only; implementation and wiring 908/909 to it happen in the code phase, and this does NOT by itself resolve issue 589386f2.

Three Amigos to decide: the exact base-gold formula, which tiles/resources yield gold and how much, whether buildings add gold (recommend deferring buildings), and reconciling this gold-income basis with the Round-5 design note that tribute is \"a % of city yields before upkeep.\"",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Size-4 landlocked city earns 3 base gold a turn", verified: false},
      %{description: "A freshly founded size-1 city earns 1 base gold a turn", verified: false},
      %{description: "A coastal size-4 city adds tile gold to its base", verified: false},
      %{description: "Growing to size 4 raises the city's gold income next turn", verified: false},
      %{description: "Online player's cities deposit their combined gold into the treasury", verified: false},
      %{description: "Offline player's gold income accrues into the capped bank", verified: false},
      %{description: "Tribute taxes the real city-derived gold income", verified: false}
    ],
    qa: %{final: :pass, attempts: 1, history: [:pass]},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Each city generates a base gold amount every turn that scales with its size (proposed: 1 + floor(size/2) gold/turn).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Size-4 landlocked city earns 3 base gold a turn",
              body: "Given Wes owns a size-4 city with no gold-yielding tiles worked
When the turn advances
Then the city produces 3 gold that turn (base = 1 + floor(4/2))"
            },
            %{
              kind: "happy path",
              title: "A freshly founded size-1 city earns 1 base gold a turn",
              body: "Given Wes founds a new size-1 city with no gold-yielding tiles worked
When the turn advances
Then the city produces 1 gold that turn (base = 1 + floor(1/2))"
            }
          ]
        },
        %{
          statement: "Worked gold-yielding tiles add their gold on top of the city base (proposed: each worked Coast tile yields +1 gold).",
          scenarios: [
            %{
              kind: "happy path",
              title: "A coastal size-4 city adds tile gold to its base",
              body: "Given Wes owns a size-4 city (base 3 gold) working 3 Coast tiles
When the turn advances
Then the city produces 6 gold that turn (3 base + 3 x 1 Coast)"
            }
          ]
        },
        %{
          statement: "A city's per-turn gold income equals its base plus its summed worked-tile gold, recomputed each turn from current size and worked tiles.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Growing to size 4 raises the city's gold income next turn",
              body: "Given a size-3 city producing 2 base gold a turn
When it grows to size 4 and works one additional Coast tile
Then the following turn it produces 4 gold (3 base + 1 Coast), recomputed from its new size and worked tiles"
            }
          ]
        },
        %{
          statement: "At each turn boundary a player's gold income (summed across their cities) is added to their treasury while online, and accrues into the capped gold bank while offline.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Online player's cities deposit their combined gold into the treasury",
              body: "Given Wes is online and owns two cities each earning 6 gold a turn
When the turn boundary resolves
Then his treasury increases by 12 gold this turn"
            },
            %{
              kind: "happy path",
              title: "Offline player's gold income accrues into the capped bank",
              body: "Given Wes is offline and his cities earn 12 gold a turn, with room under his bank cap
When the turn boundary resolves
Then the 12 gold accrues into his gold bank (story 909) instead of his treasury"
            }
          ]
        },
        %{
          statement: "This city-derived per-turn gold income is the real basis for tribute, replacing the test-only set_player_gold_income_for_test seam.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Tribute taxes the real city-derived gold income",
              body: "Given a vassal whose cities produce 12 gold a turn and a lord tribute rate of 25%
When the turn boundary resolves tribute
Then the lord skims 3 gold, computed from the real city gold income and not from set_player_gold_income_for_test"
            }
          ]
        }
      ],
      questions: [
        %{body: "Exact city base-gold formula? Proposed default is 1 + floor(size/2) gold/turn (size 4 -> 3). Alternatives: ~0.5 gold per pop rounded, or a steeper flat-per-size such as 2 x size (size 4 -> 8) if we want gold to feel closer to the ~5 base production. PO to confirm the curve.", status: :open, resolution: nil},
        %{body: "Which tiles/resources yield gold, and how much? Proposed default: worked Coast tiles +1 gold each. Open forks: do we also add a Copper-style gold bonus resource (+2 gold), which extends story 905's currently food/production-only resource set? Do rivers or any land terrain yield gold? Keeping it Coast-only avoids touching 905.", status: :open, resolution: nil},
        %{body: "Do buildings add gold (e.g. a future Market or Palace)? Recommendation: DEFER buildings to a later economy story; the foundation is base-by-size + gold tiles only. PO to confirm the defer.", status: :open, resolution: nil},
        %{body: "Reconcile tribute basis: this story makes per-turn GOLD income the tribute basis (matching QA issue 589386f2 and story 908 criterion 7674), but the Round-5 design note in feudal_vassalage_design.md says tribute is \"a % of the vassal's city YIELDS, before upkeep.\" Are these the same thing now that cities emit gold each turn, or does tribute tax gold-income specifically? PO to lock which basis 908 uses.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 913,
    status: :in_progress,
    title: "Oath Strain and Liberty Pressure",
    description:
      "As a vassal (and as a lord), I want a visible Oath Strain gauge on our relationship, so that grievance builds legibly over time and I can feel a rebellion coming — and so that a hated lord faces a bigger uprising when I finally revolt.

Source: .code_my_spec/stories/more_stories.md §7.3 + .code_my_spec/knowledge/feudal_vassalage_design.md (\"Rebellion batch — LOCKED model\", 2026-07-19).

Locked design (light mechanics, social):
- Oath Strain is a per-relationship gauge (0-100) on the Vassalage schema, visible to BOTH the lord and the vassal.
- It RISES with grievance: heavy/raised tribute, neglect (no investment), a broken Protection Pact (914), a refused call-to-arms levy. It FALLS with good lordship: investment in the vassal, granted autonomy, shared enemies/campaigns.
- Slow and sticky — it moves over many turns, not in one tick, so it reads as a genuine relationship arc.
- It does NOT gate rebellion (declaring independence is always available). Its JOB is to SIZE the temporary rebellion army when the vassal revolts (915): higher strain = a bigger uprising. It is the grievance lever; the lord's global Honor + tribute rate is the separate lever that decides which cities rise.
- Depends on Vassalage/Tribute (907/908), Protection Pact (914), Levy. Behind :feudal_enabled.

Three Amigos: the exact accrual/decay rates per driver, the strain→army-size curve, and how the gauge is surfaced to both sides (color, label, tooltip breakdown of drivers).",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Both lord and vassal see the same strain gauge", verified: false},
      %{description: "High tribute rate drifts strain upward over time", verified: false},
      %{description: "An unhonored Protection Pact spikes strain", verified: false},
      %{description: "Lord concessions ease strain", verified: false},
      %{description: "Strain does not swing within a single turn", verified: false},
      %{description: "Max strain never auto-rebels", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Every Vassalage carries an Oath Strain gauge from 0 to 100, visible to both the lord and the vassal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Both lord and vassal see the same strain gauge",
              body: "Given Wes is a vassal sworn to Lord Mira with an Oath Strain of 42
When Wes opens his oath panel and Mira opens her Vassals panel
Then both see the same gauge reading 42 out of 100 for that bond
And the value is clamped to the 0-100 range at all times"
            }
          ]
        },
        %{
          statement: "Oath Strain rises from extraction and neglect: a high tribute rate, an unhonored Protection Pact (a large spike), and a refused or withdrawn call to arms.",
          scenarios: [
            %{
              kind: "happy path",
              title: "High tribute rate drifts strain upward over time",
              body: "Given Wes pays a 50% tribute rate, well above the 25% default, with no offsetting lord obligations
And his current Oath Strain is 30
When several hours of turns pass with the rate unchanged
Then his Oath Strain drifts upward toward a ceiling implied by the imbalance (illustratively +1 to +2 per hour)
And the gauge shows the rate as the driving contributor"
            },
            %{
              kind: "happy path",
              title: "An unhonored Protection Pact spikes strain",
              body: "Given Wes is under attack and his lord fails to respond within the protection window (story 914)
And his Oath Strain is 45
When the pact is marked unhonored
Then his Oath Strain takes a large one-time spike (illustratively +25, to 70)
And a refused or withdrawn call to arms applies a smaller rise (illustratively +10)"
            }
          ]
        },
        %{
          statement: "Oath Strain falls from investment: lord gifts, a granted autonomy or lowered tribute rate, and a shared enemy against a common foe.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Lord concessions ease strain",
              body: "Given Wes has an Oath Strain of 70
When Lord Mira lowers his tribute rate from 50% to 20% and gifts him a warrior
Then his Oath Strain eases downward (illustratively -10 for the gift plus a lowered ceiling from the rate cut)
And if Mira and Wes share a common enemy, strain eases further toward that lowered ceiling"
            }
          ]
        },
        %{
          statement: "Oath Strain is slow and sticky: it moves on the scale of hours rather than per-turn, so the social and chat layer has time to operate before it shifts.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Strain does not swing within a single turn",
              body: "Given Wes has an Oath Strain of 70 after a spike
When a single 60-second turn processes with no new events
Then his strain moves by at most a small sticky increment, not a full reset
And it holds near 70 across many turns until a real change (a concession or fresh grievance) shifts it over hours"
            }
          ]
        },
        %{
          statement: "Oath Strain never auto-fires a rebellion and never gates the ability to declare independence — declaring is always available. Its one mechanical job is to SIZE the temporary rebellion army when the vassal revolts: higher strain means a bigger uprising. Which of the vassal's cities rise is decided separately, by the lord's Honor and tribute rate.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Max strain never auto-rebels",
              body: "Given Wes has an Oath Strain of 95 (\"the powder is dry\")
When many turns process and Wes never clicks Declare Independence
Then no rebellion fires automatically and Wes remains a vassal
And the high strain only sets the size of the temporary rebellion army he could raise should he choose to declare (story 915) — it does not decide which cities rise, and it never acts on its own"
            }
          ]
        }
      ],
      questions: [
        %{body: "Exact strain rise/fall rates: what per-hour drift does each source contribute, and what is the unhonored-Protection-Pact spike magnitude (illustratively +25) vs. a refused call to arms (+10)? Are rises a drift toward an imbalance-implied ceiling, or flat additive events?", status: :open, resolution: nil},
        %{body: "The slow-sticky time constant: over what real-world duration (hours? a day?) should strain traverse a meaningful span, and what is the max per-turn delta cap that enforces stickiness?", status: :open, resolution: nil},
        %{body: "Is strain modeled as a value chasing a computed target (tribute imbalance sets a ceiling the gauge drifts toward) or as an accumulator of discrete +/- events? This determines whether concessions lower a ceiling vs. subtract a fixed amount.", status: :open, resolution: nil},
        %{body: "UI surfacing: does the gauge show a breakdown of contributing factors (which grievances/investments drive the current value) to both parties, or only the single 0-100 number? A breakdown invites negotiation but exposes the lord's neglect explicitly.", status: :open, resolution: nil},
        %{body: "Tuning (deferred to build/architecture): the exact accrual and decay rates per driver (tribute rate, broken pact spike, refused levy; gifts, autonomy, shared enemy), and the strain→rebellion-army-size curve (linear? stepped? what army does strain 100 vs strain 30 raise?).", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 914,
    status: :in_progress,
    title: "Protection Pact",
    description:
      "As a vassal, I want my lord bound by a Protection Pact to defend me when I am attacked, so that vassalage is a reciprocal bargain and a lord who abandons me pays for it in reputation.

Source: .code_my_spec/stories/more_stories.md §7.4 + .code_my_spec/knowledge/feudal_vassalage_design.md (\"Rebellion batch — LOCKED model\", 2026-07-19).

Locked design (reciprocity, social consequence):
- When a vassal's city or units come under attack by a third party, the lord is notified and is expected to defend (they may already control the vassal's units under the \"defend when attacked\" stewardship rule).
- HONORING the pact (helping repel the attack) builds the lord's Honor and EASES Oath Strain (913) on that relationship.
- BREAKING the pact (ignoring a vassal left to be overrun) costs the lord a PUBLIC, world-visible Honor hit and SPIKES Oath Strain. This is the main way a lord's Honor erodes from bad lordship — and low Honor is what makes cities rise in a rebellion (915).
- No hard mechanical lock forcing the lord to act; the enforcement is reputational (Honor) + relational (strain), matching the light/social direction.
- Depends on Vassalage (907), Honor (908), Oath Strain (913), Stewardship defend-rule (910). Behind :feudal_enabled.

Three Amigos: what counts as \"under attack\" (the hp<max_hp proxy vs a first-class flag), the notification, the exact Honor/strain deltas for honoring vs breaking, and any grace window before a break is scored.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A player siege on a vassal city triggers the pact", verified: false},
      %{description: "Protection call is visible to lord and vassal with a countdown", verified: false},
      %{description: "Lord relieves the siege in time", verified: false},
      %{description: "Lord ignores the call and breaks the oath", verified: false},
      %{description: "Repeated honored protection makes vassalage a net-positive", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A lord bears a binding Protection Pact duty to defend any vassal that comes under attack, whether by barbarians or by another player.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A player siege on a vassal city triggers the pact",
              body: "Given Wes is a vassal of Lord Mira and a rival player begins besieging Wes's city
When the attack is registered
Then a Protection Pact obligation is created against Lord Mira for that attack
And the same obligation arises if the attacker is a barbarian warband rather than a player"
            }
          ]
        },
        %{
          statement: "When a vassal comes under attack, a protection call is raised that the lord can see, with a response window that counts down.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Protection call is visible to lord and vassal with a countdown",
              body: "Given Wes's city has come under attack
When the protection call is raised
Then Lord Mira sees a \"Wes is under attack — respond within N turns\" call and Wes sees \"protection requested from Mira\"
And a response window counts down (illustratively 3 turns) toward the honored/broken resolution"
            }
          ]
        },
        %{
          statement: "Honoring a protection call by relieving the vassal within the window lowers that vassal's Oath Strain and builds the lord's Honor.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Lord relieves the siege in time",
              body: "Given a protection call on Wes with a 3-turn window and Wes at Oath Strain 55
When Lord Mira's army defeats or drives off the attacker before the window expires
Then the call resolves as honored, Wes's Oath Strain falls (illustratively -15, to 40)
And Mira's Honor rises (illustratively +3)"
            },
            %{
              kind: "happy path",
              title: "Repeated honored protection makes vassalage a net-positive",
              body: "Given Lord Mira has honored three protection calls for Wes over many turns
When Wes weighs his position
Then his Oath Strain sits low despite paying tribute, because protection has been reliably delivered
And this is the \"vassalage isn't always negative\" upside — Wes gains defense he could not muster alone"
            }
          ]
        },
        %{
          statement: "Letting a protection call expire unanswered is a broken oath: the lord takes a public Honor hit and every vassal in the lord's realm takes an Oath Strain spike.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Lord ignores the call and breaks the oath",
              body: "Given a protection call on Wes with a 3-turn window and Lord Mira also holds vassals Ada and Bo
When the window expires with no relieving action from Mira
Then the call resolves as broken: Mira's Honor takes a public hit (illustratively -8)
And Wes takes the large unhonored-pact strain spike (per 913, illustratively +25)
And Ada and Bo each take a smaller realm-wide contagion spike (illustratively +8)"
            }
          ]
        }
      ],
      questions: [
        %{body: "What counts as \"failing to protect\"? Is the trigger a full siege (city taking HP damage) or any adjacent hostile? Define the response window (illustratively 3 turns) and what constitutes a valid response — must the lord's unit engage/defeat the attacker, or merely arrive within proximity of the besieged city?", status: :open, resolution: nil},
        %{body: "Exact Honor and strain deltas: honored call (vassal strain -? , lord Honor +?) vs. broken call (lord Honor -?, attacked-vassal strain +?, realm-wide contagion spike +? per other vassal). Should the broken-oath penalty scale with realm size (more vassals = bigger reputational cost)?", status: :open, resolution: nil},
        %{body: "Grief guardrail: a vassal could bait a weak attack (or invite a friendly rival) to force a no-win protection call and farm the lord's Honor loss. Do we need a cooldown, an attacker-strength threshold, or a distance/relief-feasibility check so only genuine, answerable attacks count?", status: :open, resolution: nil},
        %{body: "Is the pact always-on for every vassal, or an explicit contract term the lord can grant/withhold (per the reciprocal contract in the design)? If withheld, is there still a milder strain consequence for leaving a vassal undefended?", status: :resolved, resolution: nil},
        %{body: "What counts as \"under attack\" that raises a protection call — the existing hp<max_hp proxy, or a first-class \"under attack\" flag? And how long is the response window before an unanswered call is scored as a broken oath?", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 915,
    status: :in_progress,
    title: "Declare Independence and Free Your Cities",
    description:
      "As a vassal, I want declaring independence to launch a real, first-class war of liberation, so that subjugation is never permanent — my cities rise to me based on how my lord ruled, and a temporary uprising rallies to fight it.

Source: .code_my_spec/stories/more_stories.md §8.1/§8.2 + .code_my_spec/knowledge/feudal_vassalage_design.md (\"Rebellion batch — LOCKED model\" + \"Round 2 — first-class Rebellion\", 2026-07-19). This story is the START of the rebellion; story 919 is its END.

Locked design (light mechanics, social):
- Declare Independence (with a warning) CREATES a first-class Rebellion entity (status = active) — rebel, former lord, contested/risen cities, the temporary army, started turn — persisted via the WorldServer delta. The Vassalage is severed, tribute stops, and the rebellion is now a declared, ongoing war.
- Occupied cities RISE BACK based on the LORD'S REPUTATION — the lord's world-visible Honor + the tribute rate paid. A dishonorable/greedy lord's cities flock back; a just lord's may STAY LOYAL (retaken only by normal siege, 906). Reputation decides — no dice-roll, and the outcome is inspectable before committing.
- A TEMPORARY REBELLION ARMY spawns, sized by GRIEVANCE (Oath Strain). It fights the war; it disbands when the rebellion ENDS (story 919), not on a blind timer.
- Rebellion is its own abstraction — NOT a generic War; ordinary siege between unrelated players is unchanged.
- Depends on Oath Strain (913), Honor/tribute (908/914), Vassalization (907), Siege (906). Behind :feudal_enabled.

Three Amigos: the city-rise threshold formula (Honor + tribute), the temp-army size formula (from strain), the Rebellion record's fields, and the declare/results UI.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Declaring independence severs the oath and opens war", verified: false},
      %{description: "Vassal previews which cities will rise before committing", verified: false},
      %{description: "A risen city de-occupies and its garrison defects", verified: false},
      %{description: "A tyrant's cities rise and a grievance army rallies", verified: false},
      %{description: "A just lord's cities stay loyal and little rises", verified: false},
      %{description: "Cities that stay loyal must be taken by siege, and the lord is notified", verified: false},
      %{description: "Declaring independence opens a tracked rebellion", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Clicking Declare Independence, after a confirming warning, immediately severs the Vassalage, stops tribute, and declares war with the former lord.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Declaring independence severs the oath and opens war",
              body: "Given Wes is a vassal of Lord Mira paying 40% tribute
When Wes clicks Declare Independence and confirms the warning
Then the Vassalage is severed, no further tribute transfers from Wes to Mira
And a state of war exists between Wes and Mira"
            }
          ]
        },
        %{
          statement: "When a vassal declares independence, each occupied city rises back to the vassal based on the LORD'S REPUTATION — the lord's world-visible Honor and the tribute rate the vassal was paying. A dishonorable or greedy lord's cities flock back; a just, light-handed lord's cities may stay loyal. Reputation decides — no per-city dice roll, and the outcome is inspectable before the vassal commits.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Vassal previews which cities will rise before committing",
              body: "Given Wes has Oath Strain 80, paid 40% tribute, and Lord Mira has low Honor
When Wes opens the Declare Independence preview
Then each occupied city is marked \"will rise\" or \"stays loyal\", driven by Mira's low Honor and the 40% tribute rate — most of Mira's cities show \"will rise\"
And the preview shows the size of the temporary rebellion army his strain-80 grievance will raise
And the outcome is shown before he commits, so there is no hidden dice roll to surprise him"
            }
          ]
        },
        %{
          statement: "A city that rises has its occupation removed, its garrison defects to the returning owner, and the owner controls it again.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A risen city de-occupies and its garrison defects",
              body: "Given one of Wes's occupied cities qualifies to rise under Mira's low Honor and high tribute rate
When the uprising resolves
Then that city's occupied status is removed and Wes controls it fully again
And the lord's garrison stationed there defects to Wes"
            }
          ]
        },
        %{
          statement: "Declaring independence spawns a TEMPORARY rebellion army whose size scales with Oath Strain (the grievance against this lord) — a hated lord faces a bigger uprising. These units fight the war of independence and then DISBAND once independence is secured or after a fixed number of turns. They are a surge, not a permanent army.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A tyrant's cities rise and a grievance army rallies",
              body: "Given Wes has 5 occupied cities under Lord Mira, who has low Honor and levied 40% tribute, and Wes's Oath Strain is 80
When Wes declares independence
Then Mira's dishonor and heavy tribute make most of the five cities rise back to Wes
And a temporary rebellion army sized by Wes's strain-80 grievance spawns to fight the war
And those units are flagged temporary and will disband once the war is won or after the set number of turns
And a results banner reads \"Your cities rise — a rebellion rallies to your cause!\""
            },
            %{
              kind: "failure path",
              title: "A just lord's cities stay loyal and little rises",
              body: "Given Wes declares independence against Lord Ada, who has high Honor, levied only light tribute, and against whom Wes's Oath Strain is low
When the uprising resolves
Then few or none of Ada's occupied cities rise — a just lord keeps his subjects' loyalty
And only a small temporary force, or none at all, spawns, because low grievance raises little
And Wes remains at war with Ada with those cities still to be taken by force"
            }
          ]
        },
        %{
          statement: "Cities that do not rise stay loyal to the lord and can only be retaken by normal siege (story 906) — there is no separate reconquest mechanic. The former lord is notified of the declaration and of which cities rose.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cities that stay loyal must be taken by siege, and the lord is notified",
              body: "Given 3 of Wes's 5 cities rose and 2 stayed loyal to Mira
When the uprising resolves
Then the 2 loyal cities remain occupied by Mira and can only be freed by normal siege (story 906)
And Mira receives a notification \"Wes has declared independence!\" listing which cities rose"
            }
          ]
        },
        %{
          statement: "Declaring independence creates a first-class Rebellion record with status \"active\" that persists the conflict — the rebel, the former lord, the contested and risen cities, the temporary army, and the start turn. The war is a real tracked entity, not a transient event, and everything downstream (win/lose/peace, disband, heir) keys off it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Declaring independence opens a tracked rebellion",
              body: "Given Wes is a vassal of Lord Mira
When Wes declares independence
Then a Rebellion record is created with status \"active\", naming Wes as the rebel and Mira as the former lord
And it records the contested and risen cities, the spawned temporary army, and the start turn
And later resolution, disband, and heir logic all read from that one record"
            }
          ]
        }
      ],
      questions: [
        %{body: "Exact flip formula and weights: is the base still §8.1's simple \"tribute rate + years×5\", or the richer design formula (strain + committed strength ratio + surprise + grudges - lord Honor)? Give each term's weight/scale, the min/max clamp on final flip chance, and how Oath Strain maps to base % (e.g. strain 80 → 55%).", status: :open, resolution: nil},
        %{body: "Army-spawn counts: confirm 2 warriors per flipped city and 1 consolation warrior on total failure. Do garrison-defector units count on top of the 2/city spawn, or are they the same units? Any cap on total spawned warriors for a large realm?", status: :open, resolution: nil},
        %{body: "What defines \"committed strength\" and \"surprise\" for a lone declaration (no coordination)? Is surprise a flat bonus when the lord is at war elsewhere / distracted, and how is the vassal's own army strength folded in versus the lord's local garrison strength?", status: :open, resolution: nil},
        %{body: "Declare/results UI: does the preview show per-city odds with the itemized contributor breakdown, and does the vassal roll all cities at once on declaration or can they be staged? Where does the results banner and the lord's notification surface?", status: :open, resolution: nil},
        %{body: "Two numbers to pin in build: the city-rise threshold formula (how the lord's Honor + the tribute rate combine to decide whether a given occupied city rises vs stays loyal), and the disband condition for the temporary army (war-end detection vs a fixed N turns — and what N).", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 916,
    status: :in_progress,
    title: "Coordinated Rebellion (Pact of Broken Oaths)",
    description:
      "As a group of vassals under one lord, we want to plot our rebellion together in a private chat and rise as one, so that overthrowing a powerful lord is a social drama of trust and betrayal — not a spreadsheet of bonuses.

Source: .code_my_spec/stories/more_stories.md §8.3 + .code_my_spec/knowledge/feudal_vassalage_design.md (\"Round 2 — first-class Rebellion, Pact-in-chat\", 2026-07-19).

Locked design (PURELY SOCIAL, chat-bound):
- The Pact of Broken Oaths is a first-class object BOUND TO A CHAT. A vassal opens a pact chat and invites fellow vassals of the same lord; chat membership IS the conspiracy roster. Members agree a strike turn and each commits or declines in secret.
- The INFORMER'S DILEMMA is first-class: ANY chat member can secretly BETRAY the plot to the lord for a reward (tribute forgiveness, land), and the informer's identity stays hidden from the other conspirators. So you must weigh whom you invite into the room.
- At the strike, committed members each open/join their own Rebellion (915) together — power is NUMBERS and many oaths breaking at once, with NO mechanical coordination bonus. Each rebel still gets their own reputation-driven city uprising and strain-sized army.
- The lord may sense conspiracy \"heat\" (rising aggregate strain among their vassals) and pre-empt with concessions before the strike.
- Depends on chat/Known Players, Vassalage (907), Oath Strain (913), Rebellion (915). Behind :feudal_enabled.

Three Amigos: the pact-chat object (how invites/commit/strike are tracked on it), how betrayal is surfaced and rewarded, and how the lord perceives heat.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Wes opens a pact chat and invites two fellow vassals into it", verified: false},
      %{description: "The roster stays secret until the strike", verified: false},
      %{description: "Strike turn reveals and fires all revolts at once", verified: false},
      %{description: "An invitee informs the lord and betrays the plot", verified: false},
      %{description: "Lord reads rising heat and buys off the plot", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A vassal opens a Pact of Broken Oaths as a private chat and invites fellow vassals of the same lord into it — membership of the pact chat IS the conspiracy roster. Members agree a strike turn hours out, and each commits or declines in secret.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Wes opens a pact chat and invites two fellow vassals into it",
              body: "Given Wes, Ada, and Bo are all vassals of Lord Mira
When Wes opens a Pact of Broken Oaths chat naming strike turn 50 (about 2 hours out) and invites Ada and Bo into it
Then Ada and Bo each join the pact chat and can commit or decline in secret
And only fellow vassals of the same lord (Mira) are eligible to be invited into the chat"
            }
          ]
        },
        %{
          statement: "Committed strength is hidden from the lord and from the other conspirators until the strike — no one sees the full roster before the reveal.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The roster stays secret until the strike",
              body: "Given Ada has committed and Bo has declined before turn 50
When Wes checks the pact before the strike
Then Wes cannot see who has actually committed, only that invites are outstanding
And Lord Mira cannot see the roster or committed strength at all"
            }
          ]
        },
        %{
          statement: "At the strike turn all commitments reveal simultaneously and every committed conspirator declares independence together, each resolving its own city uprising and its own strain-sized rebellion army via story 915. Their power is numbers and the shared war breaking many oaths at once — there is no mechanical coordination bonus.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Strike turn reveals and fires all revolts at once",
              body: "Given Wes and Ada committed and Bo did not, with strike turn 50
When turn 50 processes
Then Wes's and Ada's commitments reveal simultaneously and both declare independence in the same tick
And each resolves its own occupied-city uprising and its own strain-sized army via story 915, with no coordination bonus — their strength is simply two oaths breaking at once"
            }
          ]
        },
        %{
          statement: "Any member of the pact chat can secretly inform the lord of the plot for a personal reward. Informing changes no odds (there are none) — it warns the lord, who can then pre-empt: brace defenses, reposition the Lord unit, or buy off conspirators before the strike turn. The informer's identity stays hidden from the other chat members.",
          scenarios: [
            %{
              kind: "failure path",
              title: "An invitee informs the lord and betrays the plot",
              body: "Given Bo was invited to the pact and chooses to inform Lord Mira
When Bo informs
Then Mira learns of the plot (the strike turn and/or the roster) and Bo receives a reward such as tribute forgiveness or granted land
And Mira can now pre-empt — brace defenses, reposition the Lord unit, or buy off conspirators with concessions before turn 50
And Bo's identity as the informer stays hidden from the other conspirators"
            }
          ]
        },
        %{
          statement: "The lord sees conspiracy heat — whisper volume and temperature — not its content, and can make pre-emptive concessions to cool strain before the strike turn.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Lord reads rising heat and buys off the plot",
              body: "Given whisper volume among Mira's vassals rises, showing Mira a hot unrest needle but not the messages
When Mira lowers tribute rates and honors an overdue protection call before turn 50
Then the conspirators' Oath Strain cools, shrinking the temporary armies their revolts would raise
And some conspirators may drop out rather than strike, turning the plotting window into a negotiation"
            }
          ]
        }
      ],
      questions: [
        %{body: "Commit/reveal mechanism and timing window: how far out can a strike turn be set (min/max hours), can invitees be added after opening, is a commitment revocable before the strike, and what happens to a committed vassal who goes offline through the strike turn — auto-fire or auto-drop?", status: :open, resolution: nil},
        %{body: "Coordination-bonus curve: what is the exact superlinear function of the number of synchronized rebels (e.g. quadratic, +15%×N plus a squared term), and is it capped? §8.3 baseline was linear +15% per additional rebel (max +45%) — how far above linear do we go and where does it saturate?", status: :resolved, resolution: nil},
        %{body: "Informer payoff and penalty: what exactly does an informer receive (tribute forgiveness amount, land, station rise), and how large is the informer_penalty to the remaining conspiracy's odds? Balance so informing is tempting but does not make every conspiracy collapse — where is that line?", status: :open, resolution: nil},
        %{body: "What exactly does \"heat\" show the lord? A single realm-wide unrest needle, or per-vassal temperature? Does it reveal that a pact exists, a rough conspirator count, or the strike-turn proximity? And is generating heat tied to whisper volume specifically, or to strain level?", status: :open, resolution: nil},
        %{body: "Concurrency floor: coordinated conspiracy needs several vassals under one lord at once. On small worlds a lord may rarely hold 3+ vassals — do we degrade gracefully to 1-on-1 duels, or gate this story's UI/bonus behind a minimum vassal count?", status: :open, resolution: nil},
        %{body: "Is the Pact of Broken Oaths a chat-only social convention (players just agree in chat and each hits Declare Independence), or a lightweight first-class \"pact\" object that tracks a strike turn + secret commitments and fires them together? The informer and hidden-roster rules assume the latter — confirm we want that object.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 917,
    status: :in_progress,
    title: "Lord's Death — Seize the Moment",
    description:
      "As a vassal, I want a slain lord to be a real opening I can seize — and as a dynasty, I want the bloodline to endure — so that killing a lord is a succession crisis, not a permanent erasure.

Source: .code_my_spec/stories/more_stories.md §8 + .code_my_spec/knowledge/feudal_vassalage_design.md (\"Round 2 — Heir\", 2026-07-19). This is the DEFEAT-THE-LORD arc's consequence.

Locked design (notify + choose, then the heir returns):
- When a lord's Lord unit is killed in combat (by anyone), every vassal is NOTIFIED with a prominent \"Your lord has fallen — seize the moment\" prompt. Each vassal CHOOSES whether to declare independence (915). No forced cascade, no buff — the same seize-the-moment mechanics apply.
- The realm is leaderless only for the duration of the resulting war. When the war ENDS (no active rebellion against the realm — see 919), an HEIR RESPAWNS AT THE REALM'S CAPITAL, resuming lordship over every vassal who did NOT win independence. Vassals who secured freedom during the leaderless window stay free. The dynasty survives, minus whoever slipped away.
- If a lord dies with no rebellion raised at all, the heir respawns after a short delay.
- Depends on combat/Lord unit, Vassalage (907), Rebellion (915/919). Behind :feudal_enabled.

Three Amigos: the notification/modal copy and dwell, exactly when \"the war is over\" fires the heir respawn (last active rebellion resolves), the heir unit's spawn state/strength, and the no-rebellion short-delay value.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A slain lord's vassals are all told to seize the moment", verified: false},
      %{description: "The death breaks no oath on its own", verified: false},
      %{description: "Seizing the moment liberates through the normal path", verified: false},
      %{description: "A leaderless realm cannot answer or retaliate", verified: false},
      %{description: "The heir returns to the capital when the war is over", verified: false},
      %{description: "The heir keeps the vassals who never broke away", verified: false},
      %{description: "A quiet death still brings an heir, after a short delay", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "When a lord's Lord unit is killed in combat by anyone, every vassal of that lord is immediately notified with a prominent prompt: \"Your lord has fallen — seize the moment.\"",
          scenarios: [
            %{
              kind: "happy path",
              title: "A slain lord's vassals are all told to seize the moment",
              body: "Given a lord holds three vassals across the world
And the lord's Lord unit is engaged by a rival army
When the Lord unit is killed in combat
Then each of the three vassals receives a prominent \"Your lord has fallen — seize the moment\" prompt
And the prompt links directly to the Declare Independence action"
            }
          ]
        },
        %{
          statement: "A lord's death forces nothing: no oath auto-breaks and no vassal gains any mechanical buff. Each vassal independently CHOOSES whether to declare independence — those who prefer the arrangement, or fear the war, may stay vassals of the fallen lord's realm.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The death breaks no oath on its own",
              body: "Given a lord with two vassals is killed in combat
When the death is processed on the turn tick
Then neither vassal's Vassalage is severed automatically
And neither vassal gains any combat or economic buff from the death
And on the next turn one vassal declares independence while the other chooses to remain a vassal of the leaderless realm"
            }
          ]
        },
        %{
          statement: "A vassal who seizes the moment declares independence through the normal story-915 path — cities rise on the fallen lord's Honor and tribute record, and a strain-sized temporary rebellion army spawns. The death is only the opening; the liberation mechanics are unchanged.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Seizing the moment liberates through the normal path",
              body: "Given a vassal whose lord has just fallen, whose Oath Strain is high, and whose fallen lord had low Honor
When the vassal chooses Declare Independence from the seize-the-moment prompt
Then their occupied cities rise according to the fallen lord's Honor and tribute record
And a temporary rebellion army sized by their Oath Strain spawns to fight the war
And the outcome matches what a story-915 declaration would have produced against that same lord"
            }
          ]
        },
        %{
          statement: "A realm whose Lord unit has fallen has no lord present to answer a Protection Pact or retaliate, so a rising vassal faces no lordly counterattack unless and until the lordship is re-established. Breaking away from a leaderless realm is simply easier — by absence, not by any bonus.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A leaderless realm cannot answer or retaliate",
              body: "Given a vassal declares independence after the lord's Lord unit has fallen and has not been replaced
When the rebellion resolves over the following turns
Then no Protection Pact response is raised on the vassal's behalf and no lordly counterattack marches on the risen cities
And the ease of breaking away comes purely from the lord's absence, with no buff applied to the vassal"
            }
          ]
        },
        %{
          statement: "When the war touched off by a lord's death ends — the last active rebellion against the leaderless realm resolves (story 919) — an heir respawns at the realm's capital and lordship is re-established.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The heir returns to the capital when the war is over",
              body: "Given Lord Mira's Lord unit was killed and her vassal Wes rose in rebellion, leaving the realm leaderless
When Wes's rebellion reaches an ended status and no other rebellion against Mira's realm remains active
Then an heir Lord unit respawns at Mira's realm capital
And lordship over the realm is re-established under the heir"
            }
          ]
        },
        %{
          statement: "The respawned heir resumes lordship over every vassal who did NOT win independence during the leaderless window; vassals who secured their freedom stay free. The dynasty endures, minus whoever slipped away — a lord's death is a succession crisis, not a permanent erasure.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The heir keeps the vassals who never broke away",
              body: "Given during the leaderless window Wes won independence while fellow vassals Ada and Bo never rebelled
When the heir respawns after the war ends
Then Ada and Bo are again vassals under the heir
And Wes remains free, so the dynasty continues having lost only Wes"
            }
          ]
        },
        %{
          statement: "If a lord's Lord unit dies with no rebellion raised against the realm at all, the heir respawns after a short fixed delay rather than waiting on a war that never came.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A quiet death still brings an heir, after a short delay",
              body: "Given Lord Mira's Lord unit is killed but not a single vassal raises a rebellion
When the short fixed delay passes
Then the heir respawns at the capital with the realm fully intact
And lordship resumes without ever having waited on a war"
            }
          ]
        }
      ],
      questions: [
        %{body: "What happens to the lordship itself when the Lord unit is killed — does the realm dissolve, does lordship pass to an heir/another unit, or does it linger leaderless until re-established? The \"no lord to defend or retaliate\" rule assumes it stays vacant until re-established; confirm there is no auto-succession.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 919,
    status: :in_progress,
    title: "Winning, Losing, or Ending a Rebellion",
    description:
      "As a rebel and as a besieged lord, I want a rebellion to be a war with a real beginning and end, so that independence can be won, crushed, or settled by peace — and so that \"after the war\" is a concrete moment that disbands the uprising and settles the map.

Source: .code_my_spec/knowledge/feudal_vassalage_design.md (\"Round 2 — first-class Rebellion\", 2026-07-19). This story is the END of the arc that story 915 begins.

Locked design (first-class Rebellion lifecycle: declared -> active -> ended):
- A Rebellion (created by 915) is a persisted first-class entity with a status. It ENDS one of three ways:
  1. INDEPENDENCE WON — the rebel holds all their risen cities for N consecutive turns with no lord re-occupation. The rebel is free; the severed oath is permanent.
  2. CRUSHED — the former lord retakes and holds the contested cities (normal siege, 906) or the rebel is knocked out. The beaten rebel is re-vassalized per siege rules.
  3. NEGOTIATED PEACE — a mutually-agreed end (BOTH must accept) resolving to one of the two clean outcomes ONLY: rebel restored as a vassal, or granted full independence. Nobody loses cities in a peace; optional gold reparations (winner to loser) may sweeten it. No agreement -> the war continues to a military decision.
- ON END, exactly once: the TEMPORARY rebellion army DISBANDS, cities SETTLE to their final owners, the war state clears, and dependent effects fire (e.g. heir respawn, story 917).
- Rebellion is its own abstraction, deliberately NOT a generic War — ordinary siege between unrelated players is untouched. A PARTIAL outcome (holding some of a player's cities as tributaries without full vassalization) is a separate, DEFERRED mechanic — peace stays binary for this batch.
- Depends on Rebellion/Declare (915), Siege (906), Lord's Death/Heir (917). Behind :feudal_enabled.

Three Amigos: the \"hold for N turns\" threshold, how peace is offered/accepted (+ reparations), the crushed re-vassalization target, and the on-end ordering of disband/settle/heir.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "A rebellion is a tracked entity with one end-state transition", verified: false},
      %{description: "Holding the freed cities wins independence", verified: false},
      %{description: "The lord retakes the cities and crushes the rebellion", verified: false},
      %{description: "A negotiated peace grants independence without fighting to the end", verified: false},
      %{description: "Ending the war disbands the army and settles the map, once", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A Rebellion is a persisted first-class entity with a status of active, independence_won, crushed, or peace. It is created active by a declaration of independence (story 915) and transitions exactly once to one of the three ended statuses.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A rebellion is a tracked entity with one end-state transition",
              body: "Given Wes declared independence, creating a Rebellion with status \"active\"
When the rebellion later resolves
Then its status transitions exactly once to independence_won, crushed, or peace
And it never flips back to active on a later turn"
            }
          ]
        },
        %{
          statement: "A rebellion ends in INDEPENDENCE WON when the rebel holds all of their risen cities for N consecutive turns with no city re-occupied by the lord. The severed oath becomes permanent and the rebel is free.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Holding the freed cities wins independence",
              body: "Given Wes's rebellion is active and all of his risen cities are held by Wes
When N consecutive turns pass with no city re-occupied by Lord Mira
Then the rebellion ends with status independence_won
And the severed oath becomes permanent and Wes is free"
            }
          ]
        },
        %{
          statement: "A rebellion ends CRUSHED when the former lord retakes and holds the contested cities by normal siege (906), or the rebel is knocked out of the fight. The normal siege/vassalization rules apply to the losing rebel — including being re-vassalized on the loss of their last city.",
          scenarios: [
            %{
              kind: "failure path",
              title: "The lord retakes the cities and crushes the rebellion",
              body: "Given Wes's rebellion is active but Lord Mira besieges and retakes and holds the contested cities
When Wes loses his last city in the fight
Then the rebellion ends with status crushed
And the normal siege and vassalization rules apply to Wes, re-vassalizing him on the loss of his last city"
            }
          ]
        },
        %{
          statement: "NEGOTIATED PEACE is a mutually-agreed end that BOTH sides must accept, and it resolves to one of the two clean outcomes only: the rebel is RESTORED as a vassal, or GRANTED full independence. Nobody loses cities in a peace — optional gold reparations (winner to loser) may sweeten the deal. If the sides cannot agree, the war simply continues to a military decision. (A partial outcome — holding some cities without full vassalization — is a separate, deferred mechanic.)",
          scenarios: [
            %{
              kind: "happy path",
              title: "A negotiated peace grants independence without fighting to the end",
              body: "Given Wes's rebellion has stalemated, with Wes holding some of his cities and Mira still holding others
When Mira offers Wes full independence in exchange for gold reparations, and Wes accepts
Then the rebellion ends with status peace, Wes is fully independent, and all of his cities are his again
And Wes pays the agreed reparations to Mira
And had Wes refused the terms, the war would simply have continued"
            }
          ]
        },
        %{
          statement: "The moment a rebellion reaches any ended status, exactly once: the temporary rebellion army disbands, the contested cities settle to their final owners, the war state clears, and dependent effects fire — including the heir respawn for a leaderless realm (story 917).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Ending the war disbands the army and settles the map, once",
              body: "Given Wes's rebellion reaches an ended status with a temporary army of six warriors still fielded
When the end is processed
Then the temporary rebellion army disbands, the contested cities settle to their final owners, and the war state clears
And any heir respawn fires
And all of these effects happen exactly once, not repeatedly on later ticks"
            }
          ]
        }
      ],
      questions: [
        %{body: "Numbers/rules to pin in build: the \"hold for N consecutive turns\" independence threshold (what N, and what counts as \"holding\" a risen city); how a peace offer is expressed and what terms are negotiable beyond \"keep what you hold\"; the crushed re-vassalization path (does the rebel swear to the original lord/heir, or to whoever took the last city?); and the exact ordering of disband → settle → clear → heir on end.", status: :resolved, resolution: nil},
        %{body: "SETTLED: peace is binary — the rebel ends either restored as a vassal or fully independent; both sides must accept; nobody loses cities; optional gold reparations (winner to loser). Partial/tributary subjugation (holding some cities without full vassalization) is a separate DEFERRED mechanic, not this batch. STILL OPEN for build: the \"hold for N turns\" independence threshold (N, and what counts as holding); the crushed re-vassalization target (beaten rebel swears to the heir, the original lord, or whoever took the last city?); and the exact on-end ordering of disband -> settle -> clear -> heir.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 920,
    status: :in_progress,
    title: "Fortify a unit for a defensive bonus",
    description:
      "As a player, I want to put a unit into a fortified stance that grants a defensive combat bonus until it acts, so that holding ground is a meaningful tactical choice — the defensive counterpart to the archer's ranged Shoot action. Fortify is a first-class Units.Actions capability (the :defend catalog slot already reserved for it), with its teeth as a defensive modifier in Combat.Resolver (sitting beside the lord's adjacency aura), a persistent `fortified` stance field on the unit that clears when it acts, a Game.fortify command, and a UnitPanel button gated on :defend in the unit's actions — the same shape the archer Shoot action shipped in.",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
        %{body: "Bonus shape/size: is the fortify defensive bonus a flat additive to strength (like the lord's +2 adjacency aura) or proportional (e.g. +50% of base strength)? Recommended: +50% of base strength, applied on defense only, folded into effective_strength/2 before the wounded penalty (same ordering as the aura).", status: :resolved, resolution: nil},
        %{body: "Timing: does fortify apply immediately when chosen, or take one turn to \"dig in\" (Civ-style, bonus lands next turn)? Recommended: immediately — a \"defend now\" stance is more legible for new players.", status: :resolved, resolution: nil},
        %{body: "Clear condition: what drops the fortified stance — moving only, or moving OR attacking (including a ranged shot)? Recommended: moving or attacking — a unit that strikes out is no longer hunkered down. (Being attacked while fortified keeps the stance.)", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 921,
    status: :in_progress,
    title: "Build a Galley (naval unit)",
    description:
      "As a player, once I have researched Sailing, I want to build a Galley in a coastal city and sail it on the water, so that I can explore coastlines, reach island regions, and fight at sea. The Galley is the exemplar of the unit-tracking convention: the UNIT is its own story that OWNS its tech gate (buildable in a coastal city iff Sailing is complete) and its terrain domain (moves on water, never land) — so the research and the unit it unlocks ship together and neither can half-ship. This closes the gap where Sailing was researchable but its Galley never existed.",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
        %{body: "Embark vs water-only: does the Galley carry land units (embark/disembark), or is it a water-only unit for V1? Recommended: water-only for V1 — it moves, explores, and fights on water; transporting land units is a separate later story.", status: :resolved, resolution: nil},
        %{body: "Water domain: which water tiles can a Galley traverse — coastal water only, or deep ocean too? Recommended: coastal water for V1 (matches Sailing's \"coastal exploration\"); deep-ocean sailing waits for a later tech.", status: :resolved, resolution: nil},
        %{body: "Coastal city + spawn tile: what makes a city able to build a Galley (a city with at least one adjacent coastal-water tile?), and where does a finished Galley spawn (the nearest adjacent water tile)? Recommended: buildable in any city with an adjacent coastal-water tile; spawn on the lowest-id adjacent coastal-water tile.", status: :resolved, resolution: nil},
        %{body: "Naval combat scope for V1: what can a Galley fight — other players' galleys (PvP, feudal-gated like land PvP), coastal barbarians (none exist yet), bombard coastal cities? Recommended V1: galley-vs-galley melee through the existing Combat.Resolver (same rules as land PvP); no naval barbarians and no city bombardment yet.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 922,
    status: :in_progress,
    title: "Unit maintenance (gold upkeep per turn)",
    description:
      "As the game world, I want every player unit to cost gold upkeep each turn so that armies have a real economic cost and the gold economy has a sink (it is currently income-only and inflates). Per-type upkeep is owned by a new BrokenOaths.Units.Maintenance component (the same catalog pattern as Units.Actions): Lord/Settler/Worker/Warrior = 0 (leader, civilians, and the free starter, per Civ 6), Archer/Bronze Spearman/Galley = 1 (Ancient-era military ≈ 1 gold, per Civ 6). At the turn boundary, net income = city gold income − total unit upkeep − total building upkeep; when a player's treasury hits 0 and upkeep still outruns income, the game disbands their newest/cheapest military unit each turn (Civ-faithful) with a notification, until solvent. Numbers are tunable; the DISBAND-WHEN-BROKE consequence is confirmed.",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 923,
    status: :in_progress,
    title: "Building maintenance + the building convention",
    description:
      "As the game world, I want each city building to cost gold upkeep each turn, and I want buildings tracked with a clear story convention like units have. Establishes the BUILDING CONVENTION (companion to the unit/unlock convention): a building is its own story that owns its production cost, its effect, its tech gate, AND its gold maintenance — declared in one place (a BrokenOaths.Cities.Buildings catalog), never as scattered flags. Guardrail: a building may not ship without declaring its maintenance. Exemplar/retrofit: the Granary (currently a bare has_granary boolean, Pottery-gated) becomes the first catalog entry with upkeep 1 gold/turn. Building upkeep feeds the same net-income + disband-when-broke turn settlement as unit maintenance (story 922).",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  },
  %{
    story_id: 924,
    status: :in_progress,
    title: "Split the tick: slower unit recharge vs the economy tick (tunable)",
    description:
      "As a player, I want unit movement to recharge on a SLOWER cadence than the economy so the game stops feeling frantic (\"the turns are crack\"), while cities/resources/build queue keep their pace. Today a single turn tick (turn_seconds, default 60s) recharges unit movement AND advances everything else every minute. Split them into two tunable cadences: the economy/turn tick stays (resources, build queue, income, maintenance, combat resolution timing), and unit movement recharge fires on its own slower cadence — default 2 minutes vs the economy's 1 minute. Extracted as a per-world tunable (a balance lever), the same way turn_seconds already is. Recommended model: keep the single turn tick as the economy cadence and gate the movement-recharge phase to run every Nth turn via a tunable world field (default 2 = recharge every 2 minutes) — one timer, one tunable, functionally the \"two ticks\". Behavior-preserving when the field is 1 (recharge every turn, as today).",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
        %{body: "Model: one timer with a tunable \"recharge every N turns\" multiplier (recommended — N=2 gives 2-min recharge on a 60s economy tick; N=1 is today's behavior), OR two fully-independent timers/second-values (recharge_seconds + turn_seconds, allows non-multiple cadences like 90s vs 60s but needs a second timer in WorldServer)? Recommended: the multiplier for V1; independent timers a later follow-up if a non-multiple cadence is ever wanted.", status: :resolved, resolution: nil},
        %{body: "Split boundary: \"unit recharge\" = the movement-point reset only (Turn.Movement.reset_movement), and \"everything else\" (runs every economy tick) = resources/food, build queue/production, gold income + maintenance, research/science, barbarian AI + camp spawns, weather, combat resolution timing. Confirm barbarian movement/AI stays on the fast economy tick (only PLAYER-and-barbarian movement RECHARGE slows), or should barbarian actions also slow with the recharge cadence? Recommended: only the movement-point recharge slows; every other phase (including barbarian AI) stays on the economy tick.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 925,
    status: :in_progress,
    title: "Road movement — units route along and benefit from roads",
    description:
      "As a player, I want my units to travel faster along roads and for pathfinding to route them along road networks, so that the roads I build actually matter. Reported by playtesters: units ignore roads entirely when pathing.

Root finding: roads currently have NO movement effect. Movement is uniform (every passable tile costs 1, `Unit.bfs_path` is a plain BFS with no per-tile/terrain cost), and there are no terrain movement penalties. In Civ 6, ANCIENT roads do not give a straight speed bonus either — they cost 1/tile but let units IGNORE terrain movement penalties (difficult terrain like forest/hills becomes 1); only Industrial/Modern roads reduce cost below 1 (0.75/0.5). So the Civ-faithful ancient-road benefit is moot here until terrain movement costs exist.

Two model options to decide:
- A) Civ-faithful, bigger: introduce terrain movement costs (forest/hills/marsh cost more), then roads negate them to 1 — units naturally route along roads through difficult terrain. Requires a fractional/weighted movement model (Dijkstra instead of BFS) and touches unit_stats, reset_movement, resolve_orders, and every movement test.
- B) Simpler, immediately visible: roads give a flat movement DISCOUNT (moving road-to-road costs less, or grants a bonus step), so units travel faster along road networks regardless of terrain — the \"roads = fast travel\" players expect, even though it's the later-era Civ behavior. Still needs a weighted-path model (roads preferred + cheaper).

Either way this is a movement-model change (weighted pathfinding + a road-aware cost), not a small tweak. Deferred build pending the model decision; numbers to be Civ-grounded.",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
        %{body: "Movement model: (A) Civ-faithful — add terrain movement costs (forest/hills/marsh cost more) and roads negate them to 1, so units route along roads through difficult terrain; or (B) simpler — a flat road discount (road-to-road moves cost less or grant a bonus step) for immediate \"roads = fast travel\". Both require replacing the plain BFS with a weighted shortest-path (Dijkstra) that knows per-tile cost. Recommendation: start with B for an immediate, legible benefit, and grow into A when terrain movement costs land as their own story. Which model?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 926,
    status: :in_progress,
    title: "Alliance Configuration — delegated unit control",
    description:
      "As a user, I'd like to set a military control agreement that governs how another player may command MY units — None, Defensive-only, or Full — so my civilization isn't defenceless while I'm offline, without handing over control I don't intend.

This applies to BOTH allies AND the lord-vassal relationship. The same three-level model (None / Defensive-only / Full) configures a lord's control over a vassal's units and a vassal's over a lord's, each direction independently.

DECISIONS (Three Amigos, resolved by PM):
- Three levels: None (default), Defensive-only, Full.
- Defensive-only: the delegate may attack ANY hostile unit inside my borders and may fortify/garrison my units, but may NEVER move my units outside my territory.
- Full: each grant is flagged offline-only (delegate may act only while I am disconnected) OR always-on. Both modes must be built.
- Per-relationship and one-directional: my grant over my own units is independent of the other player's grant over theirs; configured separately for each ally and for each lord-vassal direction.
- Eligibility: only an established relationship (an accepted alliance or a lord-vassal bond) may be granted a control level; strangers never.
- Trust-based: orders a delegate issues to my units are NOT logged, there is no order feed, and I cannot undo them.
- No disband: a delegate may never disband my units at any level — move, attack, and fortify only.
- A delegate acts only within the combat rights I myself hold (never bypasses no-PvP-in-Stone-Age); revocation takes effect immediately.

IMPLEMENTATION NOTE: extends the existing Feudal.Stewardship acting-on-behalf path (story 910). Reuse steward eligibility, the Players.Presence offline gating, and the Unit.persist_order! / Turn.move_now seams already built for issuing orders on another player's behalf; combat still funnels through Resolver.pvp_target_allowed?/3. Story 926 governs the unit/military surface; economy delegation stays under Stewardship's existing constructive-only rules.

OPEN QUESTION for PM: offline-detection mechanism for offline-only grants — Presence has no last_seen/heartbeat, so a network blip flips the owner offline instantly. Likely needs a last_seen timestamp plus a grace window (threshold TBD). See the open red card on this story.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Newly accepted ally cannot move my units", verified: false},
      %{description: "Owner sets each of the three levels for different allies", verified: false},
      %{description: "Granting control to an accepted ally succeeds", verified: false},
      %{description: "Granting control to a non-ally is rejected", verified: false},
      %{description: "No order feed exists for a delegate's orders", verified: false},
      %{description: "Full-control ally cannot start a war I could not start myself", verified: false},
      %{description: "Defensive-only ally repels an attacker on my city", verified: false},
      %{description: "Defensive-only delegate cannot move my units outside my territory", verified: false},
      %{description: "Revoked ally's next order is refused", verified: false},
      %{description: "Defensive-only delegate strikes a raider that just entered my borders", verified: false},
      %{description: "Offline-only Full grant: delegate acts while I am disconnected", verified: false},
      %{description: "Offline-only Full grant: delegate blocked while I am online", verified: false},
      %{description: "Always-on Full grant: delegate acts even while I am online", verified: false},
      %{description: "Full-control delegate cannot disband my unit", verified: false},
      %{description: "My grant to an ally does not grant me control of theirs", verified: false},
      %{description: "Lord-vassal bond qualifies for a control grant", verified: false},
      %{description: "Lord commands an offline vassal's units under offline-only Full control", verified: false},
      %{description: "Vassal's grant to lord is independent of lord's grant to vassal", verified: false},
      %{description: "Granting steward production applies to every city at once", verified: false},
      %{description: "Without the grant, a steward cannot set production in any city", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Delegated control offers exactly three levels — None (the default), Defensive-only, and Full.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Newly accepted ally cannot move my units",
              body: "Given Wes and I have just formed an accepted alliance
And I have not configured any control level for Wes
When Wes attempts to issue a move order to one of my units
Then the order is rejected because his control level is None
And my unit does not move"
            },
            %{
              kind: "happy path",
              title: "Owner sets each of the three levels for different allies",
              body: "Given I have accepted alliances with Mara, Wes, and a third ally
When I set Mara to Full, Wes to Defensive-only, and the third ally to None
Then each ally's granted permission matches exactly the level I chose
And no fourth level is selectable"
            }
          ]
        },
        %{
          statement: "A control level may be granted only within an established relationship — an accepted alliance or a lord-vassal bond; a stranger can never be granted control.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Granting control to an accepted ally succeeds",
              body: "Given Mara and I have an accepted alliance
When I grant Mara Full control of my units
Then the grant is saved and Mara may issue orders per the Full level"
            },
            %{
              kind: "failure path",
              title: "Granting control to a non-ally is rejected",
              body: "Given I have merely discovered a player but have no accepted alliance with them
When I attempt to grant them Defensive-only control
Then the grant is rejected because they are not an accepted ally"
            },
            %{
              kind: "happy path",
              title: "Lord-vassal bond qualifies for a control grant",
              body: "Given Mara is my lord and I am her vassal
When I grant my lord Defensive-only control of my units
Then the grant is saved because the lord-vassal bond is an established relationship"
            }
          ]
        },
        %{
          statement: "Delegation is trust-based — orders a delegate issues to my units are not logged, there is no order feed, and I cannot undo them.",
          scenarios: [
            %{
              kind: "happy path",
              title: "No order feed exists for a delegate's orders",
              body: "Given Mara holds Full control of my units
When Mara moves my warrior and fortifies it while I am away
And I come back online
Then I see no order log, feed, or history of what Mara did
And there is no control to undo or reverse her orders
And the game relies on my having granted control only to a trusted ally"
            }
          ]
        },
        %{
          statement: "A delegate may act only within the combat rights I myself hold — delegation never bypasses the no-PvP-in-Stone-Age rule.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Full-control ally cannot start a war I could not start myself",
              body: "Given Mara holds Full control of my units
And I have no active war or combat exception against player Z
When Mara orders my unit to attack player Z's unit
Then the attack is rejected with the same not-hostile refusal I would receive if I issued it myself"
            }
          ]
        },
        %{
          statement: "Under Defensive-only, a delegate may attack any hostile unit inside my borders and may fortify or garrison my units, but may never move my units outside my territory.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Defensive-only ally repels an attacker on my city",
              body: "Given Wes holds Defensive-only control of my units
And a hostile unit is attacking my city
When Wes orders my garrison to strike that attacking unit
Then the order is allowed because it is a defensive response to an active attacker"
            },
            %{
              kind: "failure path",
              title: "Defensive-only delegate cannot move my units outside my territory",
              body: "Given Wes holds Defensive-only control of my units
When Wes orders my army to march out beyond my borders to attack a neutral enemy's city
Then the order is rejected because Defensive-only may never move my units outside my territory"
            },
            %{
              kind: "happy path",
              title: "Defensive-only delegate strikes a raider that just entered my borders",
              body: "Given Wes holds Defensive-only control of my units
And a hostile unit has crossed into my borders but has not yet attacked anything
When Wes orders my unit to attack that hostile inside my territory
Then the order is allowed because the target is a hostile inside my borders"
            }
          ]
        },
        %{
          statement: "Lowering or revoking a delegate's control level takes effect immediately.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Revoked ally's next order is refused",
              body: "Given Mara held Full control of my units
When I set Mara's control level to None
And Mara then attempts to move one of my units
Then the order is rejected immediately because her level is now None"
            }
          ]
        },
        %{
          statement: "Under Full control, each grant is configured as either offline-only (the delegate may act only while I am disconnected) or always-on.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Offline-only Full grant: delegate acts while I am disconnected",
              body: "Given I granted Mara Full control flagged offline-only
And I am currently disconnected
When Mara moves and attacks with my units
Then her orders are allowed because I am offline"
            },
            %{
              kind: "failure path",
              title: "Offline-only Full grant: delegate blocked while I am online",
              body: "Given I granted Mara Full control flagged offline-only
And I am currently online
When Mara attempts to move one of my units
Then the order is rejected because I am not offline"
            },
            %{
              kind: "happy path",
              title: "Always-on Full grant: delegate acts even while I am online",
              body: "Given I granted Mara Full control flagged always-on
And I am currently online and active
When Mara moves and attacks with my units alongside her own
Then her orders are allowed because the grant is always-on"
            },
            %{
              kind: "happy path",
              title: "Lord commands an offline vassal's units under offline-only Full control",
              body: "Given I am a vassal and I granted my lord Full control flagged offline-only
And I am currently disconnected while an enemy threatens my cities
When my lord moves and attacks with my units to defend my realm
Then her orders are allowed because I am offline and my lord holds Full control"
            }
          ]
        },
        %{
          statement: "A delegate may never disband my units under any control level — delegated control permits only move, attack, and fortify.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Full-control delegate cannot disband my unit",
              body: "Given Mara holds Full control of my units
When Mara attempts to disband one of my units
Then the order is rejected because disband is never a delegated action, whatever the level"
            }
          ]
        },
        %{
          statement: "Each control grant is per-relationship and one-directional — my grant over my own units is independent of the grant the other player sets over theirs, and is configured separately for each ally and each lord-vassal direction.",
          scenarios: [
            %{
              kind: "happy path",
              title: "My grant to an ally does not grant me control of theirs",
              body: "Given I grant Mara Full control of my units
And Mara has not granted me any control of her units
When I attempt to move one of Mara's units
Then my order is rejected because the grant is one-directional and she set my level to None over her units"
            },
            %{
              kind: "happy path",
              title: "Vassal's grant to lord is independent of lord's grant to vassal",
              body: "Given I am a vassal who granted my lord Full control of my units
And my lord has separately granted me only Defensive-only control of her units
When each of us issues orders to the other's units
Then my lord may command my units at Full level while I may only defend with hers, because each direction is configured independently"
            }
          ]
        },
        %{
          statement: "The permission that lets a steward/ally set my cities' PRODUCTION is a single empire-wide toggle (all my cities at once), not a per-city setting — granting it applies to every city I own; the delegate cannot be allowed on some cities but not others.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Granting steward production applies to every city at once",
              body: "Given I own several cities
And I turn ON the single \"allow my steward to set my production\" toggle
When my steward queues production in ANY of my cities while I am offline
Then it is accepted
And the same grant already covers every other city I own — I never enabled it city by city"
            },
            %{
              kind: "failure path",
              title: "Without the grant, a steward cannot set production in any city",
              body: "Given the \"allow my steward to set my production\" toggle is OFF
When my steward tries to queue production in one of my cities
Then it is refused
And there is no per-city override that would let them do it in some of my cities but not others"
            }
          ]
        }
      ],
      questions: [
        %{body: "Defensive-only: is it TERRITORY-BOUND? Decide whether a Defensive-only ally may command my units only while those units stand on (or move within) my own territory, or anywhere on the map so long as the action is defensive. Options: (A) strictly inside my borders; (B) my borders plus adjacent tiles (matches the existing Stewardship emergency-defend rule, which only allows a move to a strictly-adjacent tile); (C) anywhere, as long as the target is actively attacking me or my ally. No clean Civ 6 analog — Civ has no offline territory-scoped delegated defense; the nearest reference is our own Stewardship (story 910), whose emergency `defend` is capped at a single adjacent-tile move. Recommend (B) for consistency with Stewardship unless the PM wants a broader mobile defense.", status: :resolved, resolution: nil},
        %{body: "Defensive-only: what ACTIONS does it permit beyond striking an active attacker? Three sub-decisions: (1) Counter-attack only (unit may strike a hostile that is currently attacking me/my ally) vs. may strike ANY hostile unit that has entered my land even before it attacks. (2) May the ally reposition/move my units defensively (pull a unit back to a threatened city) or only fight in place? (3) May the ally fortify/garrison my units? Civ 6 analog is thin — fortify is a standard defensive posture, so allowing fortify/garrison but forbidding offensive movement is the natural line. Codebase anchor: Stewardship's `defend` today allows only a single adjacent defensive move while the owner is `under_attack?`; it does NOT allow standalone fortify. Recommend: allow reactive strike + defensive repositioning + fortify/garrison; forbid moving a unit onto a tile to initiate combat with a non-attacker.", status: :resolved, resolution: nil},
        %{body: "Full control: is it OFFLINE-GATED or always-on delegation? Decide whether a Full-control ally may command my units only while I am offline (so my civ isn't defenceless while I sleep — the story's stated intent) or at all times once granted. And if offline-gated: how is \"offline\" defined? Our Presence module (`Players.Presence`) is an ephemeral live-connection registry with NO last_seen / heartbeat timestamp — `online?` is simply \"holds a LiveView connection right now.\" That means a player who briefly drops connection would flip to offline instantly. Sub-decisions: (A) offline-gated vs always-on; (B) if offline-gated, do we add a grace period / last_seen timestamp so a 30-second disconnect doesn't hand control to an ally mid-battle; (C) what happens if I come back online mid-turn while my ally is issuing orders — does control cut immediately? Codebase anchor: existing Stewardship is strictly offline-gated (`fetch_context` returns `{:error, :owner_online}`). No Civ analog (Civ has no offline concept); this is the core persistent-MMO-specific mechanic. Recommend offline-gated to match Stewardship, but flag that a last_seen grace window is likely needed.", status: :resolved, resolution: nil},
        %{body: "Attribution & safety — UNDO, CAP, and PENALTY. Three safety levers to decide: (1) UNDO — when I come back online, can I reverse orders an ally issued on my behalf? Movement generally can't be un-moved (a unit that walked into an ambush is dead), so \"undo\" may realistically mean only \"cancel still-queued orders\" rather than rewind resolved ones — confirm the PM's expectation. (2) CAP — is there a limit on how many of my units an ally may move (per turn, or total), to bound griefing? Options: no cap / N units per turn / a fraction of my army. (3) PENALTY — should abusing delegated control (e.g. marching my army off a cliff) carry an Honor/sabotage penalty for the ally, mirroring Stewardship's existing `sabotage: true` StewardLog flag and Honor hit (`sabotage_honor_penalty`)? No Civ analog (Civ co-op players can't grief each other's units). Recommend: reuse the StewardLog + sabotage-penalty machinery; cap at a per-turn unit count; \"undo\" = cancel unresolved queued orders only.", status: :resolved, resolution: nil},
        %{body: "Interaction with existing PvP-exception paths — may delegation EVER let an ally exceed my own combat rights? Rule already says delegation can't bypass no-PvP-in-Stone-Age (all cross-player combat funnels through `Resolver.pvp_target_allowed?/3`, which only permits Protection-Pact besieger strikes and active Rebellion war). Two edge decisions: (1) If I have an active Protection Pact call (a besieger I'm entitled to strike) or an active Rebellion war, may my Full-control ally use MY units to prosecute that fight on my behalf while I'm offline? This is the closest thing to a Civ 6 \"joint war\" analog — but here it's an ally fighting THROUGH my units, not alongside their own. (2) Conversely, should a Full-control ally be able to commit my units to help defend THEM (e.g. strike a unit besieging my ally's city)? That would be a NEW PvP exception that I could not invoke for myself unless the target were also attacking me. Decide whether delegated defense of an ally opens combat rights I don't personally hold, or stays strictly bounded by my own `pvp_target_allowed?` result. Recommend: strictly bounded to my own combat rights in v1 (no new exceptions); revisit joint-war-through-my-units later.", status: :resolved, resolution: nil},
        %{body: "Setting shape: PER-ALLY or GLOBAL, and SYMMETRIC or ONE-DIRECTIONAL? (1) Do I set one control level per individual ally (I trust Mara with Full but Wes with None), or one global level applied to all allies? The story leans per-ally; recommend per-ally. (2) Is the grant one-directional (I grant Mara control of MY units; that says nothing about her granting me control of hers) or symmetric/mutual (accepting an alliance-config sets the same level both ways)? Note the substrate mismatch: our Alliance record is SYMMETRIC (one canonical row per pair, `player_a/player_b`), whereas delegated control is inherently DIRECTIONAL (it's about whose units are being commanded). So even if the alliance is symmetric, the control grant almost certainly needs its own directional record. Civ 6 team/hotseat control is symmetric-by-team; but that's a lobby setting, not a per-relationship in-game grant. Recommend: per-ally AND one-directional, each side configures their own units independently.", status: :resolved, resolution: nil},
        %{body: "Revocation: what happens to orders ALREADY QUEUED when I revoke? Rule says revocation is immediate for any NEW order. But orders in our engine can be queued (`persist_order!` / `bfs_path` multi-tile moves resolve over turns via `Turn.move_now`). Decide: when I lower or revoke an ally's control, do orders they already queued but that haven't fully resolved (a) get cancelled immediately, (b) finish their current step then stop, or (c) play out to completion? This matters most for a multi-turn march the ally started — revoking mid-march could strand my army. No Civ analog. Recommend: cancel unresolved queued orders on revocation (safest against a departing ally who queued a bad move), but confirm — the PM may prefer \"finish current step\" to avoid stranding units on a hostile tile.", status: :resolved, resolution: nil},
        %{body: "Can a controlling ally DISBAND my units, or only move/attack/fortify? The existing Stewardship path structurally FORBIDS disband (`:steward_disband_unit` returns `{:error, :not_constructive}`) — deleting someone's units is treated as destructive/sabotage-shaped. Decide whether Full control keeps that prohibition or opens a narrow exception. The one arguable case: an offline owner is hemorrhaging gold to unit maintenance and heading for bankruptcy (Mara's ledger concern), and a Full-control ally disbanding a unit could save the treasury. But disband is irreversible and a prime griefing vector. No Civ analog. Recommend: NO disband under any delegated level in v1, matching Stewardship; if maintenance-relief is desired, handle it through the economy path (already partly covered by Stewardship's bank/production powers) rather than unit deletion.", status: :resolved, resolution: nil},
        %{body: "Scope vs. existing Stewardship (story 910): is 926 the UNIT-COMMAND widening of Stewardship, or a parallel system? Stewardship already lets an offline owner's lord / fellow-vassal / accepted-ally act for them, but is deliberately default-closed on units (only emergency adjacent defensive moves; ordinary move and attack are hard `{:error, :not_allowed}`; bank sweep and constructive production are allowed). Two scoping decisions: (1) Should 926 be implemented by widening Stewardship's eligibility/permission lattice (add per-ally control level that unlocks `:steward_queue_move` / `:steward_attack`) rather than a separate subsystem? Recommend yes — reuse `steward_role`, `StewardLog`, presence gating, and the public `Unit.persist_order!` / `Turn.move_now` seams already built for acting-on-behalf. (2) Does Full delegated control ALSO cover economy (bank collection, production) as Stewardship does, or is 926 strictly units and the economy powers remain governed by Stewardship's own rules? Decide whether \"Full control\" means full military only, or full civ. Recommend: 926 governs the military/unit surface; keep economy delegation under Stewardship's existing constructive-only rules unless the PM wants a single unified \"Full = full civ\" grant.", status: :resolved, resolution: nil},
        %{body: "OPEN (PM to decide) — Offline detection for offline-only Full grants. The offline-only mode is decided, but HOW do we detect that the owner is offline? Our Presence module (`Players.Presence`) is an ephemeral Registry keyed on a live LiveView connection — `online?` is literally \"holds a socket right now,\" with NO last_seen / heartbeat timestamp. Consequences to resolve: (1) A brief network blip flips the owner to offline instantly, which would hand control to the delegate mid-session and yank it back seconds later — do we add a last_seen timestamp + a grace window (e.g. offline only after N minutes with no connection)? (2) If the owner reconnects while the delegate is mid-order, does control cut immediately at the next order, or is there a settling period? (3) Do we surface \"you are acting because X is offline\" to the delegate so they know their window is live? Existing Stewardship already gates on this same `online?/2` and inherits the same blip problem, so the answer likely applies to both. Recommend adding a `last_seen` timestamp with a grace window; needs PM sign-off on the exact threshold.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 927,
    status: :in_progress,
    title: "Workers chop woods and rainforest",
    description:
      "As a user, I want my workers to chop down woods and rainforest to gain a one-time production boost to the nearest city and clear the tile, so I can accelerate a nearby city's builds and open terrain for farms/other improvements.

Civ 6 grounding: removing a Woods/Rainforest feature via a Builder yields a one-time production lump to the city that owns/works the tile; the yield scales over the game; chopping consumes a Builder charge and removes the feature (Rainforest chop historically also leaves the tile and can affect appeal). Tech gating in Civ 6: chopping Woods needs Mining; Rainforest needs Bronze Working. Update the Worker story/rules and the unit-and-unlock + charges conventions. Open design (Three Amigos): exact production yield + whether it scales, which city receives it (nearest owned? must be within borders?), tech gate, whether it costs a worker charge like Farm/Mine, and interaction with the road/terrain-cost model (removing woods lowers movement cost).",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Worker chops a woods tile and a nearby city gains a production lump", verified: false},
      %{description: "Chop lump advances the city's active build immediately, once", verified: false},
      %{description: "Chop is offered once the feature-removal tech is researched", verified: false},
      %{description: "Chop is blocked before the required tech is researched", verified: false},
      %{description: "Chop only appears on woods/rainforest tiles", verified: false},
      %{description: "No chop on a featureless tile", verified: false},
      %{description: "Chopping woods drops the tile's movement cost and removes the woods yield modifier", verified: false},
      %{description: "Cleared tile becomes eligible for a Farm", verified: false},
      %{description: "Feature on unowned land cannot be chopped", verified: false},
      %{description: "Chop allowed on a feature inside the player's borders", verified: false},
      %{description: "A chop spends one worker charge", verified: false},
      %{description: "A worker with no charges left cannot chop", verified: false},
      %{description: "A later-game chop yields a larger lump than an early one", verified: false},
      %{description: "Chopping a tile the city is working reassigns its citizens next turn", verified: false},
      %{description: "Cannot chop a tile an enemy unit holds", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Chopping a Woods or Rainforest feature removes the feature from the tile and grants a one-time production lump to the city that owns the tile.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Worker chops a woods tile and a nearby city gains a production lump",
              body: "Given a worker standing on a Woods tile that lies within the player's borders
And the player has researched Mining
When the worker chops the woods
Then the Woods feature is removed from the tile
And a one-time production lump is credited to the city that owns the tile"
            }
          ]
        },
        %{
          statement: "The chop lump is added to the receiving city's production immediately, advancing and possibly completing its active build; any surplus beyond the current build carries into the next queued item. It is a one-time lump, never a recurring per-turn yield.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Chop lump advances the city's active build immediately, once",
              body: "Given a receiving city part-way through building a Warrior that costs 40 production
When a chop credits a one-time lump larger than the Warrior's remaining cost
Then the Warrior completes this turn
And the surplus production carries into the city's next queued build
And no further production is credited from the chop on later turns"
            }
          ]
        },
        %{
          statement: "A worker can only chop a feature once its unlocking tech is researched: Mining unlocks chopping Woods, Bronze Working unlocks chopping Rainforest.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Chop is offered once the feature-removal tech is researched",
              body: "Given a worker on a Woods tile within the player's borders
And the player has researched Mining
When the player inspects the worker's actions
Then a chop action is available on that tile"
            },
            %{
              kind: "failure path",
              title: "Chop is blocked before the required tech is researched",
              body: "Given a worker on a Rainforest tile within the player's borders
And the player has not researched Bronze Working
When the player inspects the worker's actions
Then no chop action is available on that tile"
            }
          ]
        },
        %{
          statement: "The chop action is only valid on a tile that actually carries a Woods or Rainforest feature; tiles without those features offer no chop.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Chop only appears on woods/rainforest tiles",
              body: "Given a worker on a Rainforest tile with the required tech researched
When the player inspects the worker's actions
Then a chop action is available"
            },
            %{
              kind: "failure path",
              title: "No chop on a featureless tile",
              body: "Given a worker on a bare grassland tile with no Woods or Rainforest feature
When the player inspects the worker's actions
Then no chop action is available"
            }
          ]
        },
        %{
          statement: "After a chop the tile's worked yields and its movement cost are recomputed from the now-featureless terrain.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Chopping woods drops the tile's movement cost and removes the woods yield modifier",
              body: "Given a worked grassland+Woods tile yielding 2F 1P with movement cost 2
When the worker chops the woods
Then the tile reverts to bare grassland yielding 2F 0P
And the tile's movement cost drops from 2 to 1"
            },
            %{
              kind: "happy path",
              title: "Chopping a tile the city is working reassigns its citizens next turn",
              body: "Given a city is currently working a grassland+Woods tile that it owns
When a worker chops the woods on that tile
Then the chop is allowed
And the tile's worked yield is recomputed without the woods modifier
And the city's citizens are reassigned on the next turn boundary
# worked-tile behavior auto-defaulted from Civ 6; PM to confirm"
            }
          ]
        },
        %{
          statement: "A chop clears the feature only; it places no improvement, but the cleared tile becomes eligible for a Farm or other improvement.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Cleared tile becomes eligible for a Farm",
              body: "Given a grassland+Woods tile that could not host a Farm while forested
When a worker chops the woods
Then the tile carries no improvement
And a Farm can now be built on the cleared grassland tile"
            }
          ]
        },
        %{
          statement: "A tile can only be chopped if the player controls it: it must lie within the player's own borders and not be held by an enemy unit; features on unowned, neutral, or enemy-occupied tiles cannot be chopped. (Enemy-occupancy clause auto-defaulted from Civ 6; PM to confirm.)",
          scenarios: [
            %{
              kind: "failure path",
              title: "Feature on unowned land cannot be chopped",
              body: "Given a worker standing on a Woods tile that lies outside every city's borders
And the player has researched Mining
When the player inspects the worker's actions
Then no chop action is available, because the tile is not within the player's borders"
            },
            %{
              kind: "happy path",
              title: "Chop allowed on a feature inside the player's borders",
              body: "Given a worker on a Rainforest tile that lies within the borders of an owned city
And the player has researched Bronze Working
When the player inspects the worker's actions
Then a chop action is available on that tile"
            },
            %{
              kind: "failure path",
              title: "Cannot chop a tile an enemy unit holds",
              body: "Given a Woods tile occupied by an enemy unit
When the player tries to chop it
Then the chop is not allowed, because the player does not control the tile"
            }
          ]
        },
        %{
          statement: "Chopping consumes one worker charge, the same as building a Farm or Mine; unlike a Road it is not charge-exempt.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A chop spends one worker charge",
              body: "Given a worker with 2 charges on a choppable tile
When the worker chops the feature
Then the worker's remaining charges drop to 1
And a worker reduced to 0 charges is consumed exactly as it would be after a Farm or Mine"
            },
            %{
              kind: "failure path",
              title: "A worker with no charges left cannot chop",
              body: "Given a worker with 0 charges remaining on a choppable tile
When the player inspects the worker's actions
Then no chop action is available"
            }
          ]
        },
        %{
          statement: "The chop lump scales with the number of technologies researched: a Woods chop = 20 + 8 per tech (~20 at game start, ~52 at the full 4-tech Stone Age tree, about 2.5x); a Rainforest chop is worth ~75% of the Woods value. (Exact numbers auto-defaulted from Civ 6 proportions; PM to confirm.)",
          scenarios: [
            %{
              kind: "happy path",
              title: "A later-game chop yields a larger lump than an early one",
              body: "Given two identical Woods tiles
When the first is chopped with 0 technologies researched and the second with all 4 Stone Age techs researched
Then the first credits 20 production and the second credits about 52 (20 + 8 per tech)
And a Rainforest chop at the same progress is worth about 75% of the Woods value"
            }
          ]
        }
      ],
      questions: [
        %{body: "CHOP YIELD AMOUNT + SCALING. What is the one-time production lump, and does it scale over the game? Civ 6 baseline: the chop yield scales with game progress (number of techs + civics researched / era), starting ~20 production early and climbing past 100 late; Rainforest chops yield less than Woods. Our economy is far smaller and compressed: Stone Age builds cost Warrior 40 / Monument 60 / Worker 60 / Settler 100, and a worked woods tile makes only ~1P/turn (stone_age_yields.md), so a single 20 lump is already ~5-15 turns of production. We also have no era progression inside the Stone Age yet to scale against. Options: (A) flat lump, recommend ~15-20 P for Woods and less for Rainforest; (B) scale by techs-researched like Civ, but our tree is only 4 techs so the ramp is shallow; (C) flat now, reserve a scaling hook for later ages. Recommend A (flat, Woods > Rainforest) for the MVP with scaling deferred. Also decide: does overflow past the current build carry into the next item (Civ carries chop overflow), or is it capped at finishing the current build?", status: :resolved, resolution: nil},
        %{body: "WHICH CITY RECEIVES THE LUMP + BORDER REQUIREMENT. The story says \"nearest city.\" Civ 6 baseline: a Builder can only remove a feature on a tile INSIDE your own borders, and the yield credits the city that owns that tile — there is no \"nearest city\" concept and you cannot chop neutral/unowned land at all. Decisions: (1) Must the chopped tile be within our borders (Civ-authentic), or can a worker chop any reachable tile and route the lump to the nearest owned city? (2) If we keep \"nearest owned city,\" how is nearest measured (hex ring distance to city center) and is there a max range? (3) What happens if there is NO owned city in range / the tile is outside all borders — is the chop disallowed (Civ), or allowed but the production is wasted? Recommend mirroring Civ: require the tile be in our borders and credit the owning city; treat \"nearest\" as shorthand for \"the owning city.\" Confirm.", status: :resolved, resolution: nil},
        %{body: "TECH GATE — WHICH TECHS, OR UNGATED? Civ 6 baseline: chopping Woods requires Mining; chopping Rainforest requires Bronze Working (Marsh needs Masonry, but we have no marsh chop in scope). Both Mining and Bronze Working already ship in our Stone Age tree (civ6_tech_tree.md), so mirroring Civ costs us no new tech. Per unit_and_unlock_convention.md, a capability like this should own its tech-gate as an acceptance criterion rather than shipping ungated. Options: (A) mirror Civ exactly — Woods→Mining, Rainforest→Bronze Working; (B) single gate for both (e.g., Mining unlocks all chopping) for simplicity; (C) ungated. Recommend A since both gates already exist and it ties chopping into the tech tree cleanly. Confirm the mapping.", status: :resolved, resolution: nil},
        %{body: "DOES A CHOP COST A WORKER CHARGE? Civ 6 baseline: chopping consumes a full Builder charge, exactly like building an improvement. In our model, Farm and Mine each consume a worker charge while Road is charge-exempt (per the story description / charges convention). Options: (A) chop costs one charge like Farm/Mine (Civ-authentic — a worker gets a finite number of chops); (B) chop is charge-exempt like Road (workers can chop indefinitely). Recommend A: a chop is a one-time terrain-altering action that yields a strong production lump, so it should cost a charge and compete with Farm/Mine for the worker's limited charges — otherwise Rushdown-Rhea-style infinite chopping trivializes production. Confirm.", status: :resolved, resolution: nil},
        %{body: "MOVEMENT-COST DROP ON FEATURE REMOVAL — CONFIRM INTENDED. The new terrain/road movement-cost model (RoadModel work in flight) charges 2 movement to enter a Woods/Rainforest tile and 1 for open terrain, matching Civ 6 (Woods/Rainforest cost 2, cleared tiles cost 1). So chopping a feature drops that tile's entry cost from 2 to 1. Confirm this is intended (it is Civ-authentic and a real secondary reason to chop — clearing a path). Secondary: if a road is later built on the cleared tile, does the road's movement bonus stack on the now-1 cost, and should we coordinate the exact numbers with the RoadModel story so the two features agree?", status: :resolved, resolution: nil},
        %{body: "CHOPPING AN IMPROVED OR CURRENTLY-WORKED TILE. Civ 6 baseline: features and most improvements cannot coexist (you chop the feature first, THEN improve — the Lumber Mill on Woods is the lone exception, which we do not have), and you CAN chop a tile a city is currently working; its citizens simply reassign afterward. In our model, Farm/Mine already require a featureless tile (stone_age_yields.md), so a woods tile can't also carry a Farm/Mine — meaning \"chop an improved tile\" may be structurally impossible today. Decisions: (1) Confirm features and improvements are mutually exclusive so this case can't arise (recommend yes). (2) Can a worker chop a tile a city is actively working right now — recommend yes, allowed, with the city's citizen auto-assign re-picking a tile on the next turn boundary. (3) Any restriction on chopping a tile that a unit (friendly/enemy) currently occupies?", status: :resolved, resolution: nil},
        %{body: "FOLLOW-UP to the resolved \"yield scales, Civ 6-style\" decision — the concrete scaling metric + overflow. Civ 6 scales a chop by the running count of techs AND civics researched, which is why a late chop is worth several times an early one. Broken Oaths has NO civics and only 4 Stone Age techs, so a literal port barely scales (a 4-step ramp). Spec-writer needs two concrete calls: (1) What progress metric drives the scale in our game — techs researched (0-4 in the Stone Age), a future era index, total turns elapsed, or a hook that stays shallow now and steepens when later ages ship? Recommend scaling on a game-progress/era index (not raw tech count) with a documented early endpoint (~15-20 P for Woods, less for Rainforest, per our compressed economy where builds cost 40-100 P) and a defined late endpoint, so the curve is legible to Rushdown-Rhea-style planners. (2) Overflow: when the lump exceeds the city's remaining cost on its current build, does the surplus carry into the next queue item (Civ 6 carries chop overflow) or is it capped at completing the current build? Recommend carry-over for consistency with normal production overflow. This is the last open number blocking an implementation-ready spec.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 928,
    status: :in_progress,
    title: "Produce Wealth — convert city production to gold",
    description:
      "[DEFERRED / BACKLOG for this release. On 2026-07-21 the PM decided not to build Produce Wealth this round. The Three Amigos artifacts below (10 rules, 11 scenarios, all questions resolved) stay complete and implementation-ready for when the feature is revived; several rules carry \"PM to confirm\" tags. The Pottery gate is left as-is per the PM. Do not build this round.]

As a user, I want a city to be able to convert its production into gold instead of building something, so idle production isn't wasted and I have a lever to fund unit/building maintenance.

Civ 6 grounding: \"Build Wealth\" is a permanent production project converting hammers to gold at a fixed ratio (Civ 6 uses roughly a 4:1 production-to-gold in some eras; ratio is a design question). It never \"completes\" — it yields gold each turn while selected. Wire into the city production queue as a selectable project and surface it in the city panel. Pairs with the gold-maintenance economy already shipped. Open design (Three Amigos): the production-to-gold ratio, whether it's a repeatable project vs a queue item, whether it's always available or tech/building gated, and how it displays.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Idle production becomes gold instead of a build", verified: false},
      %{description: "Produce Wealth appears as a selectable option in the city panel", verified: false},
      %{description: "Switching to Produce Wealth stops the current build", verified: false},
      %{description: "Produce Wealth funds a maintenance deficit", verified: false},
      %{description: "Produce Wealth keeps paying and never completes", verified: false},
      %{description: "Pottery unlocks Produce Wealth", verified: false},
      %{description: "Produce Wealth is hidden before Pottery", verified: false},
      %{description: "A pillaged city cannot produce wealth", verified: false},
      %{description: "Card shows gold-per-turn and deselects by picking another item", verified: false},
      %{description: "Fractional gold carries over instead of being lost", verified: false},
      %{description: "Paused build keeps its progress across a Produce Wealth stint", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A city set to Produce Wealth converts that city's production output into gold for the player's treasury at a 4:1 ratio (4 production yields 1 gold), instead of advancing any unit or building.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Idle production becomes gold instead of a build",
              body: "Given Wes has a city producing 8 production per turn with nothing worth building
And he has researched Pottery
When he sets that city to Produce Wealth
Then on the next economy tick his treasury increases by 2 gold (8 production at the 4:1 ratio)
And no unit or building advances in that city"
            }
          ]
        },
        %{
          statement: "Produce Wealth is offered in the city production panel, the same place the player chooses units and buildings to produce.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Produce Wealth appears as a selectable option in the city panel",
              body: "Given Wes opens the production panel for one of his cities
When he views the list of things the city can produce
Then Produce Wealth is listed alongside the available units and buildings
And he can select it as the city's current production"
            }
          ]
        },
        %{
          statement: "A city produces wealth OR builds one item at a time, never both in the same turn.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Switching to Produce Wealth stops the current build",
              body: "Given a city is currently building a unit
When the player switches that city to Produce Wealth
Then the city stops advancing the unit
And from the next turn its production is converted to gold instead"
            }
          ]
        },
        %{
          statement: "Gold from producing wealth is deposited into the player's treasury on each economy tick, stacking with normal income and spent down by existing gold-maintenance costs like any other income.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Produce Wealth funds a maintenance deficit",
              body: "Given Mara's empire is running a net gold loss from unit and building maintenance
When she sets two Pottery-unlocked cities to Produce Wealth
Then on each economy tick the gold they generate stacks with her normal per-turn income
And her net treasury change per tick improves by that combined gold amount"
            }
          ]
        },
        %{
          statement: "Produce Wealth is a repeatable, never-completing project: it stays selected and pays gold every economy tick until the player changes the city's production.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Produce Wealth keeps paying and never completes",
              body: "Given a city has been set to Produce Wealth
When several economy ticks pass without the player changing its production
Then the city pays gold on every one of those ticks
And Produce Wealth never completes or falls idle
And it remains the city's selected production until the player chooses something else"
            }
          ]
        },
        %{
          statement: "Produce Wealth is gated behind the Pottery tech (our early granary/economy tech): a city cannot select it until Pottery is researched. Fallback: if the PM prefers, Build Wealth can instead be always-available from turn one. (auto-defaulted to Pottery gate pending Currency, PM to confirm)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Pottery unlocks Produce Wealth",
              body: "Given the player has researched Pottery
When they open a city's production panel
Then Produce Wealth is available to select"
            },
            %{
              kind: "failure path",
              title: "Produce Wealth is hidden before Pottery",
              body: "Given the player has not yet researched Pottery
When they open a city's production panel
Then Produce Wealth is not offered as a selectable option"
            }
          ]
        },
        %{
          statement: "A pillaged or production-halted city cannot Produce Wealth; the production halt blocks selecting or running it.",
          scenarios: [
            %{
              kind: "failure path",
              title: "A pillaged city cannot produce wealth",
              body: "Given a city's production is halted because it has been pillaged
When the player tries to set it to Produce Wealth, or it was already producing wealth when the halt occurred
Then the city produces no gold from Produce Wealth while the halt is in effect"
            }
          ]
        },
        %{
          statement: "Produce Wealth appears as a project card showing its estimated gold-per-turn, and the player deselects it by choosing another production item — there is no separate stop button. (auto-defaulted, PM to confirm)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Card shows gold-per-turn and deselects by picking another item",
              body: "Given a city's production panel shows the Produce Wealth card with its estimated gold-per-turn
When the player selects a unit or building to produce instead
Then Produce Wealth is deselected without needing a separate stop button
And the city switches to producing the chosen item"
            }
          ]
        },
        %{
          statement: "Fractional gold from the 4:1 conversion accumulates across economy ticks instead of truncating; a whole gold is paid out each time the accumulated remainder crosses 1, so no production is silently lost. (auto-defaulted, PM to confirm)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fractional gold carries over instead of being lost",
              body: "Given a city producing 10 production per tick set to Produce Wealth (2.5 gold per tick at 4:1)
When two economy ticks pass
Then the accumulated conversion is 5 gold and all 5 gold is paid out across those ticks
And the fractional remainder is carried forward rather than truncated away"
            }
          ]
        },
        %{
          statement: "Switching a city to Produce Wealth preserves the paused item's stored production; switching back later does not forfeit that progress. (auto-defaulted, PM to confirm)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Paused build keeps its progress across a Produce Wealth stint",
              body: "Given a city has accumulated partial production toward a building
When the player switches it to Produce Wealth for several ticks and then switches back to that building
Then the building resumes from its previously stored production
And none of the earlier progress is forfeited"
            }
          ]
        }
      ],
      questions: [
        %{body: "RATIO: What is the production-to-gold conversion ratio? Civ 6 baseline: \"Build Wealth\" converts hammers to gold at roughly 4 production : 1 gold (the exact ratio is our open design lever). Do we adopt ~4:1, or tune it against the already-shipped gold-maintenance economy so Produce Wealth is a meaningful-but-not-dominant income source? State the intended ratio and whether it is flat across the game or changes by era/tech.", status: :resolved, resolution: nil},
        %{body: "REPEATABLE PROJECT vs ONE-SHOT: Is Produce Wealth a permanent, repeatable project that never completes (paying gold every turn while selected), or a one-shot item the city finishes and then falls idle? Civ 6 baseline: it is a permanent, repeatable PROJECT that never completes and keeps paying gold each turn until the player changes production. Do we match that, or model it as a queue item?", status: :resolved, resolution: nil},
        %{body: "AVAILABILITY / GATING: Is Produce Wealth always available in every city from turn one, or is it gated behind a tech, civic, or building? Civ 6 baseline: the Build-Wealth-style project is generally always available with no tech or building prerequisite. Do we keep it ungated (simplest, casual-friendly for Wes), or gate it to give it a progression beat?", status: :resolved, resolution: nil},
        %{body: "ECONOMY-TICK TIMING & STACKING: Does the gold arrive on each economy tick, stacked with normal per-turn income and net against maintenance in the same treasury update? Civ 6 baseline: gold accrues each turn while the project is selected and is added to normal treasury income alongside maintenance deductions. Confirm it flows through the existing economy tick (not a separate payout), and how it is netted against maintenance in the per-turn treasury calc.", status: :resolved, resolution: nil},
        %{body: "UI / DISPLAY & SELECT/DESELECT: How does Produce Wealth appear in the city production panel, and how does the player select and deselect it? Civ 6 baseline: it shows as a project card in the production list with a gold icon and a per-turn gold estimate, selected like any other production item and replaced by simply choosing something else. Do we show the estimated gold-per-turn on the card? Is there an explicit \"stop producing wealth\" affordance, or does picking another item deselect it?", status: :resolved, resolution: nil},
        %{body: "PILLAGED / PRODUCTION-HALTED CITY: Can a pillaged or production-halted city still Produce Wealth, and what does it yield? Civ 6 baseline: gold scales with the city's currently available production, so a pillaged city with reduced output makes proportionally less gold, and a city with zero effective production yields little or none while the project stays selectable. Do we mirror that (gold tracks live production, project remains selected through the halt), or block Produce Wealth entirely while a city is pillaged/halted?", status: :resolved, resolution: nil},
        %{body: "ROUNDING / FRACTIONAL GOLD (QA): With a non-1:1 ratio, how do we handle fractional conversion? E.g. at ~4:1 a city making 10 production yields 2.5 gold. Civ 6 baseline: production accumulates and gold is paid out with fractional carryover rather than truncating every tick. Do we round down per tick (losing fractions), or accumulate the remainder across ticks so no production is silently lost? This directly affects whether small/low-production cities feel cheated.", status: :resolved, resolution: nil},
        %{body: "PARTIAL-BUILD PROGRESS ON SWITCH (Developer): When a city switches an in-progress build to Produce Wealth (and later switches back), is the accumulated production on the paused item preserved, or forfeited? Civ 6 baseline: Civ 6 banks partial production toward a build and does not permanently destroy queued progress when you swap to a project. Do we preserve the paused item's stored production, or reset it to zero when the player picks Produce Wealth?", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 929,
    status: :in_progress,
    title: "Build road to a destination",
    description:
      "As a user, I'd like to order a worker to build a road to a destination tile, auto-pathing the road along the cheapest route so I can connect cities without placing each segment by hand.

Depends on the road/terrain movement model (story 925) and the Improvement road build. The worker walks the path, laying road on each tile in sequence (consuming build time per segment). Open design (Three Amigos): does the worker auto-move-and-build tile by tile, or does it pre-mark the whole route as queued road jobs; does laying road cost worker charges (currently road is charge-exempt); what happens if the path is blocked or an enemy interrupts; can multiple workers share a route; and how the destination is chosen in the UI (click target tile). Ground routing in the same weighted-path model units use; Civ 6 auto-explore/auto-build-road via Military Engineer/Builder as a reference for feel.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Single command connects two cities with road", verified: false},
      %{description: "Route auto-paths along the cheapest weighted route", verified: false},
      %{description: "Destination with no valid path is rejected", verified: false},
      %{description: "Worker lays road segment by segment over time", verified: false},
      %{description: "Clicking the target tile previews the ghost-road path", verified: false},
      %{description: "Blocked or attacked worker cancels the whole order", verified: false},
      %{description: "Long road order consumes no worker charges", verified: false},
      %{description: "Road-to targets a tile inside the player's borders", verified: false},
      %{description: "Targeting a tile outside borders is rejected", verified: false},
      %{description: "Worker builds only the gaps and finishes at a roaded destination", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A worker can be ordered to build a road to a destination tile with a single command, instead of placing each road segment by hand.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Single command connects two cities with road",
              body: "Given Wes has a worker near City A and wants a road to City B eight tiles away
When he issues a single \"build road to\" order targeting City B
Then the worker begins building a road along the route toward City B
And Wes does not have to place any individual road segments by hand"
            }
          ]
        },
        %{
          statement: "The road follows the cheapest route between the worker and the destination, computed with the same weighted-path model units use for movement.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Route auto-paths along the cheapest weighted route",
              body: "Given a destination reachable by either a short path through difficult terrain or open terrain
When Wes orders the worker to build a road to that destination
Then the chosen route is the cheapest one under the same weighted-path model units use
And the route prefers open terrain and existing roads over higher-cost tiles"
            },
            %{
              kind: "failure path",
              title: "Destination with no valid path is rejected",
              body: "Given a destination the worker cannot reach (e.g. across water with no land route)
When Wes orders the worker to build a road to that destination
Then no route is computed and the order is rejected
And Wes is told the destination is unreachable"
            }
          ]
        },
        %{
          statement: "A single worker walks the cheapest path and lays road on each tile in sequence as it arrives, each segment taking the normal road build time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Worker lays road segment by segment over time",
              body: "Given a worker executing a \"build road to\" order over a five-tile route
When the order progresses
Then the worker lays road on one tile at a time in route order
And each segment takes the normal road build time before the next begins"
            }
          ]
        },
        %{
          statement: "The player picks the destination by clicking the target tile, and a highlighted ghost-road path is shown along the route with a per-tile progress cue while it builds. (Auto-defaulted to Civ 6 baseline, PM to confirm.)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Clicking the target tile previews the ghost-road path",
              body: "Given Wes has selected a worker and entered build-road-to mode
When he clicks the target destination tile
Then a highlighted ghost-road path is shown from the worker to the destination
And each tile shows a per-tile progress cue as the road is built"
            }
          ]
        },
        %{
          statement: "If the route is blocked or the worker is attacked mid-build, the entire order is cancelled and the player must re-issue it; there is no auto-reroute.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Blocked or attacked worker cancels the whole order",
              body: "Given a worker partway through a \"build road to\" order
When the next tile becomes blocked or the worker is attacked mid-build
Then the entire order is cancelled and the worker stops building
And the route is not auto-rerouted
And Wes must re-issue the order to continue"
            }
          ]
        },
        %{
          statement: "Laying the road segments costs no worker charge; the only cost of the order is build time.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Long road order consumes no worker charges",
              body: "Given a worker with a fixed number of charges
When it completes a \"build road to\" order spanning many tiles
Then the worker's charge count is unchanged
And only build time was spent laying the road"
            }
          ]
        },
        %{
          statement: "The destination must lie within the player's own territory; tiles outside the player's borders cannot be targeted.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Road-to targets a tile inside the player's borders",
              body: "Given Wes has a worker and a destination tile inside his own territory
When he issues a \"build road to\" order targeting that tile
Then the order is accepted and the route is computed within his borders"
            },
            %{
              kind: "failure path",
              title: "Targeting a tile outside borders is rejected",
              body: "Given a destination tile outside the player's own territory
When Wes tries to issue a \"build road to\" order targeting that tile
Then the order is not accepted
And Wes is told the destination must be inside his own borders"
            }
          ]
        },
        %{
          statement: "The worker skips tiles that already have a complete road and builds only the gaps; the order completes when every tile on the route, including the destination, is roaded. (Auto-defaulted to Civ 6 baseline, PM to confirm.)",
          scenarios: [
            %{
              kind: "happy path",
              title: "Worker builds only the gaps and finishes at a roaded destination",
              body: "Given a route where some tiles already have a complete road
When the worker executes the \"build road to\" order
Then it traverses the already-roaded tiles without rebuilding them
And it lays road only on the unroaded gap tiles
And the order completes once every tile on the route, including the destination, is roaded"
            }
          ]
        }
      ],
      questions: [
        %{body: "EXECUTION MODEL: Does the worker auto-move one tile at a time laying road as it goes, or does issuing the order pre-mark the whole cheapest route as queued road jobs the worker then services one by one? Civ 6 baseline: the Military Engineer builds roads as it MOVES along its path (move-and-build, one action at a time, autonomously per turn) rather than pre-queuing the entire route as standing jobs. Recommend mirroring move-and-build for feel, but pre-marking makes the pending route persistent and easier to render/resume. Which model?", status: :resolved, resolution: nil},
        %{body: "COST PER SEGMENT: Does laying each road segment cost a worker charge, or is it purely time-based (the road build-duration per tile) with no charge consumed? Civ 6 baseline: Military Engineer road-building consumes CHARGES (limited uses), and Builders spend a charge per improvement. In OUR current model road is charge-EXEMPT and time-based. If a multi-tile road order stays charge-exempt, one worker could road the whole map for free (only time-gated); if it consumes a charge per tile, long roads exhaust workers fast. Keep charge-exempt (time only), charge per tile, or a flat one-charge for the whole order?", status: :resolved, resolution: nil},
        %{body: "ROUTING MODEL + PREFERENCE: Confirm the road route uses the SAME weighted cheapest-path model units use, and that it prefers existing roads and open terrain over difficult/high-cost tiles. Civ 6 baseline: roads negate terrain movement cost (in our model a road tile costs 1), so pathing naturally favors existing roads. DEPENDENCY RISK: story 925 (the road/terrain movement model this routing is built on) has NOT picked model A (terrain costs + roads negate) vs B (flat road discount) yet — 929's route weights are undefined until 925 lands. Is 929 blocked on 925's decision, and do we want the road-build router to reuse the unit router verbatim or its own tuned weights?", status: :resolved, resolution: nil},
        %{body: "INTERRUPTION BEHAVIOR: When the path is blocked mid-route (an enemy or friendly unit occupies the next tile, a tile becomes impassable, or the worker is attacked/killed), does the order (1) pause and wait, (2) auto re-route to the destination, or (3) cancel and require re-issue? And separately, if the worker is ATTACKED but survives, does the build order keep going or drop? Civ 6 baseline: automated orders (auto-explore, auto-build, queued moves) typically INTERRUPT and cancel on enemy contact, forcing the player to re-issue — there is no auto re-route. Recommend halt-and-notify (matches our failure scenario) with manual resume; confirm which of pause / re-route / cancel the PM wants for each cause.", status: :resolved, resolution: nil},
        %{body: "MULTIPLE WORKERS ON ONE ROUTE: Can two or more workers share/parallelize a single build-road-to route (e.g. split the tiles so it finishes faster), or is each order strictly one worker building sequentially? Civ 6 baseline: there is NO shared multi-unit build order — each Military Engineer/Builder works independently, and you would manually stagger multiple engineers along a path. Recommend one-worker-per-order for v1 (simplest, matches Civ); confirm whether parallel/shared routes are in scope or deferred.", status: :resolved, resolution: nil},
        %{body: "UI — DESTINATION SELECTION + PENDING-ROUTE DISPLAY: Confirm the destination is chosen by clicking a target tile (vs click-drag, or clicking a city). And how is the pending route shown — a highlighted tile path, ghost road sprites on each queued tile, a line, and does it show remaining build time / progress? Civ 6 baseline: selecting a destination shows a movement-path preview with turn pips, and build actions show a progress indicator on the tile. Recommend click-target-tile plus a highlighted ghost-road path with a per-tile progress cue; confirm the interaction and how much progress detail the PM wants surfaced.", status: :resolved, resolution: nil},
        %{body: "DESTINATION TERRITORY / VISIBILITY: Must the destination (and the route tiles) be within owned or already-explored territory, or can the player road into fog, neutral, or enemy land? Civ 6 baseline: automated pathing needs EXPLORED tiles to route through (you cannot auto-path through unrevealed fog), and Military Engineers can build roads in friendly/neutral territory but are restricted in enemy land. Recommend requiring the route to lie in explored tiles and disallowing enemy-owned tiles for v1; confirm the ownership/visibility constraints on both the destination and the intervening tiles.", status: :resolved, resolution: nil},
        %{body: "SKIP ALREADY-ROADED TILES + ARRIVAL: If part of the cheapest route already has road, does the worker skip those tiles (move across without rebuilding) and only build the gaps, and does the order end when the destination tile itself is roaded or when the worker simply arrives? Civ 6 baseline: roads are never rebuilt on tiles that already have them; the engineer just traverses existing road and lays road only on unroaded tiles. Recommend skip-existing-road and treat the order as complete when every tile on the route (including the destination) has road. Confirm, and confirm whether the destination tile itself gets a road or is only the endpoint.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 930,
    status: :in_progress,
    title: "Tech-to-building coverage audit (Library and friends)",
    description:
      "As a player, when I research a technology that should grant a building (e.g. Writing → Library), I want that building to be buildable in my cities, so research feels rewarding and the tech tree is cohesive. Right now some techs unlock nothing buildable.

This is the building-convention work: audit every technology in the tree, and for each that should yield a building, ensure a building exists in the catalog and is buildable (cost, effect, tech-gate, maintenance — one catalog entry per building per the building convention). Add the missing buildings. Follow the unit-and-unlock convention's sibling (a building owns its tech gate as its own story). Open design (Three Amigos): which techs map to which buildings for our Stone/Bronze-age scope, each building's effect (yields/adjacency), cost and maintenance numbers (Civ 6-grounded), and whether any are wonders vs standard buildings. Compare Civ 6 building-per-tech coverage as the baseline.",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "The tech-to-building coverage audit table (11 Ancient techs, code-grounded 2026-07-21)", verified: false},
      %{description: "A unit/improvement/ability tech is not a gap", verified: false},
      %{description: "The Library ships as its own story that owns the Writing gate", verified: false},
      %{description: "Library lands as one catalog entry with declared maintenance", verified: false},
      %{description: "A building with no declared maintenance is rejected", verified: false},
      %{description: "Writing's unlock string is marked deferred until the Library ships", verified: false},
      %{description: "Astrology's Shrine is blocked because faith has no economy here", verified: false},
      %{description: "Library builds directly in the city, no Campus required", verified: false},
      %{description: "Proposed cost/maintenance numbers, Civ 6-grounded off the Granary baseline", verified: false},
      %{description: "RESOLVED — implementation-ready tech-to-building mapping (PM decisions 2026-07-21, Civ 6-grounded)", verified: false},
      %{description: "The initial world-wonder set (Civ 6-grounded, mapped to economies we have)", verified: false},
      %{description: "Currency tech is added to the tree and gates the Build Wealth project", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "Story 930 is an audit that enumerates, for every technology in the tree, whether it grants a buildable building today, and names each gap; it does not itself implement the missing buildings.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The tech-to-building coverage audit table (11 Ancient techs, code-grounded 2026-07-21)",
              body: "Given the eleven Ancient-era techs in BrokenOaths.Technology.Research and the sole building in BrokenOaths.Cities.Buildings (Granary, 1 gold upkeep)
When each tech is audited for \"does it grant a buildable BUILDING, and does that building exist in the catalog?\" using Civ 6 as the baseline
Then the coverage is:

| Tech (cost) | Civ 6 building on this tech | Our current unlock string | Delivered? | Building in catalog? | Verdict |
| pottery (80) | Granary | \"Granary (+2 food storage)\" | YES (has_granary) | YES (Granary, 1g) | COVERED — the exemplar |
| animal_husbandry (80) | (Pasture/Camp = improvements) | \"Pasture improvement\" | YES | n/a — improvement | OK, non-building unlock |
| mining (110) | (Mine/Quarry = improvements) | \"mines in 3 turns\" | YES | n/a — passive ability | OK, non-building unlock |
| sailing (150) | (Harbor comes later) | \"Galleys\" | YES (story 921) | n/a — unit | OK, non-building unlock |
| archery (150) | (none) | \"Archer unit\" | YES | n/a — unit | OK, non-building unlock |
| irrigation (150) | (Plantation = improvement) | \"farming irrigated resources\" | NO (structure-only) | n/a — improvement | non-building; improvement deferred, not this story |
| writing (150) | Library (in Campus) | \"Library building\" | NO (structure-only) | NO | GAP — flagship: Library |
| astrology (150) | Shrine (in Holy Site) | \"Holy Site district\" | NO (structure-only) | NO | GAP — but Civ 6 payout is faith, which we have no economy for |
| masonry (240) | Ancient Walls | \"Walls and Quarry\" | NO (structure-only) | NO | GAP — Walls (building); Quarry is an improvement |
| the_wheel (240) | Water Mill | \"roads and Heavy Chariot\" | NO (structure-only) | NO | GAP? — Water Mill (building) is optional; roads/chariot are non-buildings |
| bronze_working (240) | Barracks (in Encampment) | \"Bronze Age\" (+ units + Copper) | YES (age/units) | NO | GAP? — Barracks would be an ADDITIONAL building on an already-delivering tech |

And the building GAPS to resolve are, in priority order: Library (writing), Walls (masonry), Barracks (bronze_working, optional), Water Mill (the_wheel, optional), and Shrine/Astrology (blocked on the missing faith economy). Every other tech grants a non-building unlock and is out of scope for this story."
            },
            %{
              kind: "happy path",
              title: "RESOLVED — implementation-ready tech-to-building mapping (PM decisions 2026-07-21, Civ 6-grounded)",
              body: "Given the PM confirmed: fill in each mapping from Civ 6 defaults, don't force a building onto every tech, include a few wonders, and add a Currency tech gating Build Wealth
When the gaps from the audit table are resolved
Then the buildings to ADD are these STANDARD per-city buildings (built once per city, directly in the city, no district), grounded in Civ 6:

| Building | Tech gate | Prod cost | Maint (gold/turn) | Effect (economy we already have) | Civ 6 source |
| Granary (already shipped) | Pottery | 60 | 1 | +2 food storage | Granary |
| Library | Writing | 90 | 1 | +2 science/turn, flat (NOT per-pop, so it doesn't compound the only science lever) | Library +2 sci |
| Ancient Walls | Masonry | 80 | 0 | city +50 max HP and +5 defensive strength — wires into the EXISTING Combat.CityDefense model (story 895: HP 100, defense 20 + 5*size + garrison) | Ancient Walls |
| Barracks | Bronze Working | 90 | 1 | +1 production toward MILITARY units built in that city | Barracks |
| Water Mill | The Wheel | 90 | 1 | +1 food +1 production to the city — river adjacency DROPPED because Broken Oaths does not model rivers | Water Mill |

And the techs that intentionally get NO building (decision 1 — a tech may grant a unit, improvement, ability, or nothing): Animal Husbandry (Pasture improvement), Mining (faster mines), Sailing (Galley), Archery (Archer), and Astrology (Civ 6 analog is the faith Shrine/Stonehenge — no faith economy, so Astrology stays a pure prerequisite/structure tech).
And every unlock string that names one of these new buildings is corrected to name it as delivered by its own building story (no dead unlocks)."
            }
          ]
        },
        %{
          statement: "A technology is not intrinsically coupled to a building; it may grant a unit, an improvement, a passive ability, or nothing at all (a pure prerequisite tech). A building is added only where Civ 6 has a clear tech-to-building analog that pays out in an economy we already have.",
          scenarios: [
            %{
              kind: "happy path",
              title: "A unit/improvement/ability tech is not a gap",
              body: "Given Archery grants the Archer (a unit), Animal Husbandry grants the Pasture (an improvement), and Mining grants faster mines (a passive ability)
When the audit checks each for building coverage
Then none is flagged as a gap, because a tech's unlock need not be a building
And only techs that SHOULD grant a building but have none in the catalog (Writing, Masonry, and the optional Barracks/Water Mill) are carried forward as gaps."
            }
          ]
        },
        %{
          statement: "Each missing building is delivered by its own story that owns its tech gate as an acceptance criterion (per the building convention), never as a line item under the tech tree.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The Library ships as its own story that owns the Writing gate",
              body: "Given the Library is a building gap on the Writing tech
When it is scheduled for delivery
Then a dedicated Library story is created whose acceptance criterion reads \"Given a city whose owner has completed Writing, the Library appears in the build menu; without Writing it does not; a built Library applies its effect\"
And that criterion cannot pass until both the Writing gate and the working Library exist, so the story can never be marked done half-built
And story 930 itself only enumerates the gap — it does not add the Library."
            }
          ]
        },
        %{
          statement: "Every building lives as a single Cities.Buildings catalog entry owning its cost, effect, tech gate, and gold maintenance, with maintenance stated explicitly (0 allowed but never omitted).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Library lands as one catalog entry with declared maintenance",
              body: "Given the Library is added to BrokenOaths.Cities.Buildings
When its catalog entry is written
Then that single entry carries its production cost, its effect, its Writing tech gate, and its gold maintenance per turn
And no Library property is wired as a scattered boolean or flag elsewhere, exactly as the Granary exemplar does it."
            },
            %{
              kind: "failure path",
              title: "A building with no declared maintenance is rejected",
              body: "Given a proposed building whose catalog entry omits a maintenance figure
When it is reviewed against the building convention guardrail
Then it is rejected, because maintenance must be explicit (a free building is a declared 0, never an omission)."
            }
          ]
        },
        %{
          statement: "A technology's unlock string must name only a delivered capability or be marked deferred with its delivering story; a structure-only tech that names a building it cannot yet deliver is a tracked gap, not a silent dead unlock.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Writing's unlock string is marked deferred until the Library ships",
              body: "Given Writing's unlock string reads \"Enables the Library building\" but no Library exists in the catalog
When the audit applies the no-dead-unlocks guardrail
Then Writing's unlock is flagged and must read \"Enables the Library building (deferred — story NNN)\" until the Library story delivers it
And the same treatment applies to Masonry (Walls) and Astrology (Holy Site/Shrine)."
            },
            %{
              kind: "happy path",
              title: "Currency tech is added to the tree and gates the Build Wealth project",
              body: "Given Build Wealth (story 928, converting production into gold) needs a tech gate, and the tree currently has no Currency tech
When the tree is audited for the techs the economy needs
Then a Currency tech is ADDED to the tree, Civ 6-grounded: prerequisite Writing (Civ 6 places Currency after Writing), a capstone-band science cost (~240), unlock string \"Enables the Build Wealth project (convert production to gold)\"
And that unlock is delivered by story 928, so its string is honest, not a dead unlock
And Build Wealth is offered in a city's production options only once the city's owner has completed Currency."
            }
          ]
        },
        %{
          statement: "A building's effect must pay out in an economy Broken Oaths already has (food, production, science, gold, or combat/HP); a Civ 6 building whose sole effect is culture or faith does not map until that economy exists.",
          scenarios: [
            %{
              kind: "failure path",
              title: "Astrology's Shrine is blocked because faith has no economy here",
              body: "Given Civ 6 puts the Shrine (+2 faith) on Astrology, and Broken Oaths has no faith economy
When the audit tries to map Astrology to a building
Then no viable building effect exists, so Astrology stays structure-only (deferred) rather than shipping a building with a no-op effect
And by contrast Library (science), Walls (combat/HP), Barracks (production/combat), and Water Mill (food/production) all pay out in economies we already have, so they are mappable."
            }
          ]
        },
        %{
          statement: "Broken Oaths has no districts in the Stone/Bronze MVP, so a building is buildable directly in the city like the Granary, with no district prerequisite standing between the tech and the build option.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Library builds directly in the city, no Campus required",
              body: "Given Civ 6 nests the Library inside a Campus district, the Shrine inside a Holy Site, and the Barracks inside an Encampment
When these buildings are mapped to Broken Oaths, which has no districts
Then each is offered in the city build menu the moment its tech gate is met, with no intervening district to build first — exactly the Granary's flat model."
            }
          ]
        },
        %{
          statement: "Each proposed building's production cost and gold maintenance are Civ 6-grounded and scaled to our economy, with the shipped Granary (60 production, 1 gold/turn) as the baseline reference.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Proposed cost/maintenance numbers, Civ 6-grounded off the Granary baseline",
              body: "Given the Granary shipped at 60 production / 1 gold (Civ 6: 65 prod / 1 gold)
When each proposed building is priced against its Civ 6 counterpart on the same ratio
Then the recommended starting numbers (for PM confirmation) are:

| Building (tech) | Civ 6 prod / gold | Proposed prod / gold | Proposed effect (economy we have) |
| Library (writing) | 90 / 1 | 90 / 1 | flat +N science/turn, or +1 science/pop — magnitude is an open question |
| Ancient Walls (masonry) | 80 / 0 | 80 / 0 | city defensive combat/HP bonus — magnitude open |
| Barracks (bronze_working) | 90 / 1 | 90 / 1 | +production toward military units, or a built-unit strength bonus — open |
| Water Mill (the_wheel) | 90 / 1 | 90 / 1 | +1 food / +1 production to the city — river-adjacency requirement open |

And these are starting points grounded in Civ 6, not final; each building's own story confirms them."
            }
          ]
        },
        %{
          statement: "Alongside standard per-city buildings, the tree carries a few world wonders: each is built once per WORLD (not per city), is unique, carries a Civ 6-grounded one-time production cost with zero maintenance, and grants a global effect in an economy we already have.",
          scenarios: [
            %{
              kind: "happy path",
              title: "The initial world-wonder set (Civ 6-grounded, mapped to economies we have)",
              body: "Given the PM asked for a few world wonders alongside standard buildings
When wonders are chosen from Civ 6's early wonders, keeping only those whose effect maps to an economy we already have
Then the initial wonder set is:

| Wonder | Tech gate | Prod cost | Maint | Effect (economy we have) | Civ 6 source |
| Pyramids | Masonry | ~220 | 0 | grants a free Worker plus +1 build charge to Workers (we have workers) | Pyramids (free Builder + charges) |
| Hanging Gardens | Irrigation | ~220 | 0 | +15% city growth (food accrual) for all of the builder's cities | Hanging Gardens (+15% growth) |

And each wonder is built once per world: once any player completes it, it is removed from every other city's build menu (one-per-world, unlike the repeatable-per-city standard buildings).
And Hanging Gardens gives the Irrigation tech a real payoff it otherwise lacked; Pyramids sits on Masonry beside Ancient Walls exactly as Civ 6 does.
And Stonehenge (Astrology) and Great Bath (Pottery) are deliberately NOT included, because their Civ 6 effect is faith/housing, economies we do not have; more wonders can be added later as those economies land."
            }
          ]
        }
      ],
      questions: [
        %{body: "MAPPING (a): Which structure-only techs should each get a building for our Stone/Bronze scope, and which stay unit/ability-only? Civ 6 baseline building-per-tech: Writing→Library (Campus), Masonry→Ancient Walls, Astrology→Shrine (Holy Site), Bronze Working→Barracks (Encampment), The Wheel→Water Mill. Recommendation from the audit: ship Library (Writing) and Walls (Masonry) as the core gaps; treat Barracks (Bronze Working) and Water Mill (The Wheel) as optional additions; keep Astrology structure-only until a faith economy exists. Confirm the list to build.", status: :resolved, resolution: nil},
        %{body: "LIBRARY EFFECT (b): Civ 6 Library = +2 science + 1 Great Scientist point, sitting in a Campus. We have no districts and no great people, and science is a flat 2/pop (the pop lever rolls Civ's Palace+Campus+Library into one number). So what does OUR Library do — a flat +N science/turn per city, or +1 science per pop (which would raise the size-4 ceiling from 8 to 12)? Recommend a flat bonus (e.g. +2 or +4 science/turn) so it doesn't compound the only science lever. Pick the shape and magnitude.", status: :resolved, resolution: nil},
        %{body: "WALLS EFFECT (b): Civ 6 Ancient Walls = +100 outer-defense HP, a wall ranged attack, and higher city combat strength. Our combat.ex uses a single base_strength per unit and the curve 30*e^(0.04*(atk-def)). Do our cities even have a defense strength / garrison HP for Walls to boost? If yes, Walls should add city combat strength and/or a defensive HP pool (Civ-like); if cities are not yet defensible, Walls may need a city-combat model first (bigger dependency — flag it). Confirm the effect and whether a city-defense model is a prerequisite.", status: :resolved, resolution: nil},
        %{body: "BARRACKS EFFECT (b): Civ 6 Barracks (Bronze Working, in Encampment) = +1 production toward land units, +25% unit XP, +1 housing, +1 Great General point. We have no XP, housing, or great people. Bronze Working already delivers (age + Spearman/Swordsman + Copper), so a Barracks would be an ADDITIONAL building on an already-delivering tech. Should it exist, and if so does it give +production toward military units built in that city, or a flat strength bump to units trained there? Recommend +production toward military units (reuses production, no new system). Confirm whether to build it at all.", status: :resolved, resolution: nil},
        %{body: "WATER MILL / THE WHEEL (a,b): Civ 6 Water Mill (The Wheel) = +1 food +1 production, extra food from adjacent rice/wheat, and MUST be built next to a river. The Wheel currently gates nothing (its roads/Heavy Chariot are deferred). Do we want a Water Mill building here at all, and if so do we require river/water adjacency (do we even model rivers?), or drop the adjacency and make it a flat +1F/+1P city building? Recommendation: only add it if we already model rivers/fresh water; otherwise leave The Wheel to the future roads story. Decide.", status: :resolved, resolution: nil},
        %{body: "ASTROLOGY / FAITH GAP (a,b): Civ 6 Astrology = Holy Site district + Shrine (+2 faith). Broken Oaths has no faith or culture economy (see stone_age_yields: gold/culture/faith explicitly dropped). Options: (1) keep Astrology structure-only and mark its unlock deferred; (2) re-map Astrology to a non-faith building (e.g. a monument-style culture building — but we have no culture either); (3) re-purpose Astrology's unlock to something we DO have. Recommendation: option 1 — keep it deferred with an honest unlock string, revisit when/if a faith or culture economy is added. Confirm.", status: :resolved, resolution: nil},
        %{body: "COST & MAINTENANCE (c): Civ 6 baselines (prod / gold-upkeep): Granary 65/1, Library 90/1, Ancient Walls 80/0, Barracks 90/1, Water Mill 90/1. Our shipped Granary is 60/1. Proposed off that ratio: Library 90/1, Walls 80/0, Barracks 90/1, Water Mill 90/1. Note Walls costs 0 upkeep in Civ 6 — confirm we want a deliberate 0-maintenance building (allowed by the convention). Sign off each building's production cost and gold/turn maintenance, or adjust.", status: :resolved, resolution: nil},
        %{body: "WONDERS vs STANDARD (d): In Civ 6 the buildings on these techs (Granary, Library, Ancient Walls, Barracks, Water Mill) are all STANDARD per-city repeatable buildings, not wonders. The Stone/Bronze-age WONDERS (Stonehenge on Astrology, Pyramids on Masonry, Great Bath on Pottery) are a separate one-per-world category. Recommendation: build all of these as standard buildings (built once per city, like the Granary), and treat any wonder as out of scope for story 930 / its own future story. Confirm none of these are wonders, and confirm wonders are deferred.", status: :resolved, resolution: nil},
        %{body: "MUST EVERY TECH GRANT A BUILDABLE? (e): The unit-and-unlock guardrail says every tech must deliver SOMETHING real (or mark it deferred), but not necessarily a BUILDING. Today Mining grants a passive ability (faster mines) and Irrigation grants irrigated farming — neither is a buildable thing. Civ 6 itself has techs that grant only abilities/improvements/units. Recommendation: confirm techs may legitimately grant a unit, an improvement, or a passive ability, and are NOT each required to grant a building — so the audit's job is only to close BUILDING gaps where a building is warranted, not to force one building per tech. Confirm.", status: :resolved, resolution: nil},
        %{body: "BUILD-ONCE vs REPEATABLE + STORAGE (developer/QA): The Granary is built once per city and recorded as a has_granary boolean on City; Cities.Buildings reads that flag for upkeep. Each new standard building (Library, Walls, Barracks) is likewise built once per city. Do we keep adding per-building booleans (has_library, has_walls, ...) for now, or is this the moment to migrate City to a buildings list (the convention flags this as a future story)? Recommendation: keep per-building booleans for the first one or two additions to stay consistent with the Granary, and schedule the list migration once a third building lands. Confirm the storage approach for the building stories.", status: :resolved, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 931,
    status: :in_progress,
    title: "Scout — early recon unit",
    description:
      "As a player, I want a cheap, fast Scout unit with extended vision, so that I can explore the map and find neighbors, barbarian camps, and good city sites early without risking my Lord or tying up warriors.

Civ 6 grounding: the Scout is the ancient-era reconnaissance unit — available from turn 1 with no tech prerequisite, very cheap (cheapest military build), fast (3 movement vs the Warrior's 2), high sight radius, weak in combat (can fight but is not a front-line unit), and gains recon promotions (extra sight, ignore terrain cost). In Broken Oaths it pairs directly with the fog-of-war/exploration (876) and discovery (899) mechanics and the new terrain/road movement-cost model (925) — a fast high-vision unit is what makes exploring a ~30k-tile globe practical.

Follows the unit-and-unlock convention: the Scout owns its tech gate (or \"no gate\") as its own acceptance criterion, and its stats live in Cities.Production.unit_stats/1. Open design (to confirm): tech gate (recommend none — buildable from start like Civ 6), vision radius vs the Lord's 3 (does the Scout out-scout the Lord?), movement value under our compressed scale (warrior 1 / most 2), combat capability (weak combatant vs pure non-combat), cost, and whether it interacts with the terrain movement-cost model (ignore difficult-terrain cost like a Civ 6 recon promotion?).",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Scout is buildable on turn 1 with zero techs researched", verified: false},
      %{description: "Scout costs 30 — the cheapest military build", verified: false},
      %{description: "Scout completes faster than a Warrior in the same city", verified: false},
      %{description: "Scout crosses three open tiles in one turn", verified: false},
      %{description: "Scout reveals a 2-hop vision ball", verified: false},
      %{description: "Lord out-sees the Scout by one hop", verified: false},
      %{description: "Scout attacks a barbarian camp at strength 5", verified: false},
      %{description: "Scout loses a 1v1 against a Warrior", verified: false},
      %{description: "Scout enters difficult terrain for 1 movement", verified: false},
      %{description: "Scout and Warrior pay different costs for the same woods tile", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "The Scout has no tech prerequisite — it is buildable from turn 1, and owns \"no gate\" as its own acceptance criterion per the unit-and-unlock convention.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Scout is buildable on turn 1 with zero techs researched",
              body: "Given a new city on turn 1 whose owner has researched no technologies
When the player opens the city's build menu
Then the Scout appears as a buildable option
And it sits in the always-available set alongside Settler, Worker, and Warrior — no tech ever locks it"
            }
          ]
        },
        %{
          statement: "The Scout is the cheapest military build at 30 production, strictly below the Warrior's 40.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Scout costs 30 — the cheapest military build",
              body: "Given the production catalog
When the Scout's cost is read
Then it is 30 production
And that is strictly less than the Warrior's 40, making the Scout the cheapest military unit to build"
            },
            %{
              kind: "happy path",
              title: "Scout completes faster than a Warrior in the same city",
              body: "Given a city producing a fixed amount per turn
When it builds a Scout and, separately, a Warrior
Then the Scout finishes in fewer turns, because 30 production clears before 40"
            }
          ]
        },
        %{
          statement: "The Scout moves 3 — the fastest unit in the game (Warrior 1; Lord, Settler, Worker, and Galley 2).",
          scenarios: [
            %{
              kind: "happy path",
              title: "Scout crosses three open tiles in one turn",
              body: "Given a Scout on open ground with a full movement allowance
When it moves in a single turn along open (cost-1) tiles
Then it can enter up to 3 tiles — outpacing the Warrior's 1 and every other unit's 2"
            }
          ]
        },
        %{
          statement: "The Scout's sight radius is 2 (the default), and it does not exceed the Lord's 3 — the Scout's edge is speed and terrain, not raw sight.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Scout reveals a 2-hop vision ball",
              body: "Given a Scout standing on a tile
When fog-of-war vision is computed for its owner
Then a 2-hop ball of tiles around the Scout becomes visible — the default vision radius"
            },
            %{
              kind: "happy path",
              title: "Lord out-sees the Scout by one hop",
              body: "Given a Scout and a Lord standing on the same tile
When vision is computed
Then the Lord reveals 3 hops and the Scout 2 — the Scout does not out-scout the Lord on raw sight; its advantage is reaching more tiles per turn and ignoring difficult terrain"
            }
          ]
        },
        %{
          statement: "The Scout is a weak combatant — base strength 5, half the Warrior's 10; it can attack barbarians and camps and defend itself, but is not a front-line unit.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Scout attacks a barbarian camp at strength 5",
              body: "Given a Scout adjacent to a barbarian camp
When it attacks
Then it deals damage at base strength 5 (half a Warrior's 10)
And it can also defend itself when attacked — it is a real, if weak, combatant"
            },
            %{
              kind: "failure path",
              title: "Scout loses a 1v1 against a Warrior",
              body: "Given a Scout (strength 5) attacked by an enemy Warrior (strength 10)
When combat resolves
Then the Scout takes disproportionately heavy damage and loses the exchange — confirming it is a scout, not a front-line unit, and should avoid standing in a fight"
            }
          ]
        },
        %{
          statement: "The Scout ignores the difficult-terrain movement-cost penalty — every passable land tile costs it 1 (entry_cost always 1), the Civ 6 Ranger/Alpine recon trait.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Scout enters difficult terrain for 1 movement",
              body: "Given a Scout about to enter a roadless hills, woods, rainforest, or marsh tile
When its entry cost is priced
Then the tile costs the Scout 1, not the difficult-terrain 2 — the penalty is waived for the Scout"
            },
            %{
              kind: "happy path",
              title: "Scout and Warrior pay different costs for the same woods tile",
              body: "Given a Warrior and a Scout each about to enter the same roadless woods tile
When entry cost is priced for each
Then the Warrior pays 2 (Terrain.movement_cost) but the Scout pays 1 — only the Scout waives the difficult-terrain penalty
And impassable tiles (deep water for a land unit) remain impassable — the trait discounts cost, it does not grant new domains"
            }
          ]
        }
      ],
      questions: [
        %{body: "Recon promotions: should the Scout gain Civ 6-style recon promotions over time (Spyglass +1 sight, Ranger/Alpine terrain traits)? Recommend deferring — ship a flat Scout now (no promotion system exists in Broken Oaths yet); the terrain-ignore trait is already baked in as a base ability rather than an earned promotion. (auto-defaulted, PM to confirm)", status: :open, resolution: nil},
        %{body: "Scout HP: set to 100 (the standard unit pool shared by Warrior/Archer/Galley), with the Scout's weakness expressed purely through strength 5? Recommend yes — matches Civ 6, where all units share a 100-HP pool and the Scout's fragility lives in its low combat strength. (auto-defaulted, PM to confirm)", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 932,
    status: :in_progress,
    title: "Unit movement, pathfinding and turn resolution",
    description:
      "As a player, I want unit movement to behave predictably — orders that resolve when I expect, paths that route sensibly around terrain and along roads, and units that don't mysteriously \"lose a turn\" — so that maneuvering my army feels reliable.

This is the umbrella story for the whole movement system, created to accumulate comprehensive Three Amigos scenarios for spex (SexySpex BDD) coverage, because movement is the source of most playtest issues (every-other-turn recharge, \"lord a turn behind,\" fortify seeming to cost movement, pathing weirdness). It should document and pin the CURRENT implementation as executable scenarios and surface the open decisions.

Behaviors to cover (ground scenarios in the real code: Simulation.Turn.tick, Simulation.Turn.Movement, Units.Unit.bfs_path/entry_cost, Worlds.Terrain.movement_cost, Combat interactions):
- Immediate vs queued resolution: orders execute immediately when issued (move_now) with whatever movement is left; the turn boundary recharges movement and continues the remaining path.
- Movement recharge cadence: after the timer inversion, movement recharges EVERY tick (fast layer); economy runs on the slow economy_turns cadence. (Was every recharge_turns ticks — the every-other-turn bug.)
- Terrain movement costs (925): open 1, difficult (hills/woods/rainforest/marsh) 2; a completed road negates to 1.
- Weighted pathfinding: Unit.bfs_path is Dijkstra over the mesh neighbor graph, routing along roads / cheap terrain, deterministic lowest-tile-id tie-break.
- Civ 6 min-1 rule: a unit with any movement left may always take at least one step, even onto a cost-2 tile (drops to 0).
- Lockstep simultaneous resolution + collision: one step per round per active mover, ascending unit id; a step into an occupied tile is blocked.
- Interrupted orders (OPEN DECISION): a blocked step flips the order to :interrupted and it is NOT auto-retried today — should it auto-resume next tick when the tile clears?
- Stacking exceptions: field stack (one civilian + one combat escort, same owner), own-city garrison room, broken-enemy-city walk-in.
- Fortify interaction: fortify never costs movement; moving clears the stance; being attacked does not.
- Unit-specific traits: Scout (931) ignores difficult-terrain cost; galley moves only over coastal water.

Ground balance/mechanic choices in Civ 6 first (project standing directive).",
    tags: [%{name: "gem-weary-wes"}],
    criteria: [
      %{description: "Issuing a move spends current movement this instant", verified: false},
      %{description: "Turn boundary recharges and continues the remaining path", verified: false},
      %{description: "Arrival consumes the path and drops the order", verified: false},
      %{description: "Move rejected when the requester does not own the unit", verified: false},
      %{description: "Movement resets to full on every tick", verified: false},
      %{description: "Non-economy tick still recharges and resolves movement", verified: false},
      %{description: "No every-other-turn stranding (timer-inversion regression guard)", verified: false},
      %{description: "Open terrain costs 1", verified: false},
      %{description: "Difficult terrain costs 2", verified: false},
      %{description: "Completed road negates difficult terrain to 1", verified: false},
      %{description: "An unfinished road grants no discount yet", verified: false},
      %{description: "Routes around difficult terrain when a cheaper way exists", verified: false},
      %{description: "Follows a road corridor over open ground", verified: false},
      %{description: "Equal-cost routes tie-break to the lowest tile id", verified: false},
      %{description: "Occupied intermediate tiles are avoided; destination may be occupied", verified: false},
      %{description: "No passable route yields unreachable", verified: false},
      %{description: "Movement-1 unit enters a cost-2 tile and ends at 0", verified: false},
      %{description: "A unit at 0 movement takes no further step this tick", verified: false},
      %{description: "One step per round, movers ordered by ascending id", verified: false},
      %{description: "Trailing unit follows into a tile the leader vacated this round", verified: false},
      %{description: "Step into a stationary unit is blocked and interrupts", verified: false},
      %{description: "Tile claimed earlier the same round blocks a later mover", verified: false},
      %{description: "Step into a foreign-occupied tile is blocked", verified: false},
      %{description: "Field stack: one civilian plus one combat escort share an open tile", verified: false},
      %{description: "Own-city garrison has room for a returning defender", verified: false},
      %{description: "Broken enemy city allows a walk-in past the fallen garrison", verified: false},
      %{description: "Field stack is full — second civilian or same-class is blocked", verified: false},
      %{description: "Healthy garrisoned enemy city stays blocked", verified: false},
      %{description: "Fortifying spends no movement", verified: false},
      %{description: "Moving clears the fortify stance", verified: false},
      %{description: "Stance ramps to full after a boundary held untouched", verified: false},
      %{description: "A blocked step does not clear fortify", verified: false},
      %{description: "Fortify is rejected for a non-defend-capable unit", verified: false},
      %{description: "Galley paths over coastal water", verified: false},
      %{description: "Scout ignores the difficult-terrain surcharge", verified: false},
      %{description: "Galley onto land is impassable", verified: false},
      %{description: "Land unit onto water is impassable", verified: false}
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: %{name: "Gem-Weary Wes", slug: "gem-weary-wes", type: "proto"},
      rules: [
        %{
          statement: "A move order executes immediately when issued, spending whatever movement the unit has left; the turn boundary recharges movement and continues the remaining path.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Issuing a move spends current movement this instant",
              body: "Given Rhea's warrior has movement 2 at tile A with a clear 3-tile open path to tile D
When she queues a move to tile D
Then the warrior advances two open tiles to tile C immediately (move_now), spending both points
And the order is retained with the final step (C to D) as its remaining path"
            },
            %{
              kind: "happy path",
              title: "Turn boundary recharges and continues the remaining path",
              body: "Given a unit sits mid-path at 0 movement with a remaining path still queued (status :pending)
When the next tick resolves
Then its movement is reset to max_movement first
And it continues stepping along the remaining path in the same tick"
            },
            %{
              kind: "happy path",
              title: "Arrival consumes the path and drops the order",
              body: "Given a unit is one step from its destination with movement available
When the step resolves
Then the path empties (arrival)
And the move order is removed entirely rather than left as :pending or :interrupted"
            },
            %{
              kind: "failure path",
              title: "Move rejected when the requester does not own the unit",
              body: "Given a unit belongs to another player (or the unit or player is unknown)
When a player queues a move for it
Then the command is refused with {:error, :not_owner}
And no order is persisted and nothing moves"
            }
          ]
        },
        %{
          statement: "Movement recharges to full every tick on the fast layer; the slow economy cadence never gates whether a unit can move.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Movement resets to full on every tick",
              body: "Given a unit spent all its movement last tick
When any tick resolves
Then its movement is reset to max_movement at the top of the tick, unconditionally"
            },
            %{
              kind: "happy path",
              title: "Non-economy tick still recharges and resolves movement",
              body: "Given economy_turns is 10 and the current tick is not an economy tick (rem(turn, 10) != 0)
When the tick resolves
Then units still reset movement and resolve their pending orders
And economy phases (improvement, production, food, science) are skipped that tick, but movement is not"
            },
            %{
              kind: "happy path",
              title: "No every-other-turn stranding (timer-inversion regression guard)",
              body: "Given a unit is at 0 movement on an off-economy tick
When the tick resolves
Then the unit is not stranded: movement recharges this tick like any other
And the retired recharge_turns throttle is never consulted"
            }
          ]
        },
        %{
          statement: "Entering a tile costs 1 movement on open terrain and 2 on difficult terrain (hills, woods, rainforest, marsh); a completed road negates the cost back to 1.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Open terrain costs 1",
              body: "Given a flat, feature-free tile (grassland/plains/desert/tundra/snow, no hills, no woods/rainforest/marsh)
When a unit enters it
Then the entry cost is 1 movement point"
            },
            %{
              kind: "happy path",
              title: "Difficult terrain costs 2",
              body: "Given a tile with hills relief, or a woods, rainforest, or marsh feature, and no road
When a unit enters it
Then the entry cost is 2 movement points (Civ 6 difficult-terrain cost)"
            },
            %{
              kind: "happy path",
              title: "Completed road negates difficult terrain to 1",
              body: "Given a woods-on-hills tile that carries a road with status :complete
When a unit enters it
Then the entry cost is 1, not 2 (Civ 6 road-negates-terrain rule)"
            },
            %{
              kind: "happy path",
              title: "An unfinished road grants no discount yet",
              body: "Given a difficult tile whose road is still status :building
When a unit enters it
Then the entry cost is the full terrain cost of 2 — only a completed road negates it"
            }
          ]
        },
        %{
          statement: "Pathfinding picks the least-total-cost route over the mesh, favoring roads and cheap terrain and routing around difficult terrain, with a deterministic lowest-tile-id tie-break.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Routes around difficult terrain when a cheaper way exists",
              body: "Given a forest tile sits directly between origin and destination, with an open detour whose total cost is lower
When the path is computed (Dijkstra)
Then the chosen route goes around the forest rather than beelining through it"
            },
            %{
              kind: "happy path",
              title: "Follows a road corridor over open ground",
              body: "Given a completed-road corridor and a parallel open-ground route to the same destination
When the path is computed
Then it prefers the road because each road tile costs 1 and the total cost is no higher"
            },
            %{
              kind: "happy path",
              title: "Equal-cost routes tie-break to the lowest tile id",
              body: "Given two routes of identical total cost to the destination
When the path is computed
Then the frontier key {cost, tile_id} expands the lower tile id first, giving the same route every run regardless of map iteration order"
            },
            %{
              kind: "happy path",
              title: "Occupied intermediate tiles are avoided; destination may be occupied",
              body: "Given an intermediate tile is occupied by another unit and an equally cheap free detour exists, and the destination tile itself is held by an enemy unit
When the path is computed
Then the route avoids the occupied intermediate tile
And the enemy-held destination is still accepted as the target (collision at tick time stops the mover adjacent)"
            },
            %{
              kind: "failure path",
              title: "No passable route yields unreachable",
              body: "Given the destination is passable for the unit type but every route to it is blocked by impassable tiles or occupied intermediates
When the path is computed
Then it returns no path and the move is refused with {:error, :unreachable}"
            }
          ]
        },
        %{
          statement: "A unit with any movement left may always take at least one step, even onto a cost-2 tile, ending at 0 rather than being refused.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Movement-1 unit enters a cost-2 tile and ends at 0",
              body: "Given a warrior with movement 1 adjacent to a woods (cost-2) tile
When it takes the step
Then it enters the woods and its movement is clamped to 0, not left negative (Civ 6 min-1-move rule)"
            },
            %{
              kind: "happy path",
              title: "A unit at 0 movement takes no further step this tick",
              body: "Given a unit dropped to 0 movement after entering a cost-2 tile, with path still remaining
When the round's active-mover gate is applied (movement_left > 0)
Then it is no longer an active mover and waits until the next tick recharges it"
            }
          ]
        },
        %{
          statement: "Orders resolve in lockstep rounds, one step per active mover per round processed in ascending unit id; a step into a tile occupied at that instant is blocked and interrupts the order in place.",
          scenarios: [
            %{
              kind: "happy path",
              title: "One step per round, movers ordered by ascending id",
              body: "Given two units with movement 2 both have pending multi-step paths
When a resolution round runs
Then each active mover advances exactly one step that round, processed in ascending unit id, and the round repeats until no active movers remain — deterministic every run"
            },
            %{
              kind: "happy path",
              title: "Trailing unit follows into a tile the leader vacated this round",
              body: "Given unit A (lower id) is directly ahead of unit B (higher id), both moving the same direction
When the round runs, A steps first and vacates its tile before B is processed
Then B may step into A's vacated tile that same round (no false collision against a tile the leader already left)"
            },
            %{
              kind: "failure path",
              title: "Step into a stationary unit is blocked and interrupts",
              body: "Given a mover's next tile is held by a unit that does not move this round
When the step is attempted
Then the step is blocked, the order flips to :interrupted, and the full remaining path (including the blocked step) is preserved untouched for a later re-queue"
            },
            %{
              kind: "failure path",
              title: "Tile claimed earlier the same round blocks a later mover",
              body: "Given two movers target the same empty tile the same round
When the lower-id mover claims it first
Then the higher-id mover's step into that now-occupied tile is blocked and its order flips to :interrupted"
            },
            %{
              kind: "failure path",
              title: "Step into a foreign-occupied tile is blocked",
              body: "Given a mover's next tile is held by another player's unit (not a broken city, no field-stack/garrison exception)
When the step is attempted
Then it is blocked, the order flips to :interrupted, and the mover halts adjacent (movement into an enemy tile is a combat action, not a walk-on)"
            }
          ]
        },
        %{
          statement: "A tile that is normally one-unit-only accepts a mover under three exceptions: a same-owner field stack of one civilian plus one combat unit, room in the mover's own city garrison, or an enemy city whose walls are broken.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Field stack: one civilian plus one combat escort share an open tile",
              body: "Given an open-field tile holds exactly one of Wes's combat units (warrior)
When his worker of the same owner steps onto it
Then the step succeeds — one civilian plus one combat unit of the same owner may share a field tile (either order)"
            },
            %{
              kind: "happy path",
              title: "Own-city garrison has room for a returning defender",
              body: "Given the mover's own city tile holds fewer than the garrison cap of military units
When one of the player's units steps onto the city tile
Then the step succeeds (civilians always fit uncounted; military fit up to the garrison cap)"
            },
            %{
              kind: "happy path",
              title: "Broken enemy city allows a walk-in past the fallen garrison",
              body: "Given an enemy city is broken (hp 0) and not yet captured (occupied_by_player_id is nil)
When another player's unit steps onto the city tile
Then the step succeeds despite a still-present fallen garrison (story 906 broken-city walk-in)"
            },
            %{
              kind: "failure path",
              title: "Field stack is full — second civilian or same-class is blocked",
              body: "Given an open tile already holds two units, or one unit of the SAME combat class as the mover, or a foreign-owned unit
When the mover attempts to step on
Then the step is blocked — the field-stack exception allows only exactly one civilian plus one combat unit of the same owner"
            },
            %{
              kind: "failure path",
              title: "Healthy garrisoned enemy city stays blocked",
              body: "Given an enemy city still has hp above 0 (walls intact) and a garrison unit on its tile
When another player's unit attempts to step onto the city tile
Then the step is blocked — the broken-city walk-in only applies once hp reaches 0"
            }
          ]
        },
        %{
          statement: "Fortify costs no movement; a unit that displaces loses the stance, but a unit that stays put (including one whose step was blocked) or is merely attacked keeps it.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Fortifying spends no movement",
              body: "Given a defend-capable unit at full movement
When the player fortifies it
Then it gains the stance immediately (fortified_turns 1, the partial bonus) and its movement is unchanged — fortify is not a move"
            },
            %{
              kind: "happy path",
              title: "Moving clears the fortify stance",
              body: "Given a fortified unit (fortified_turns 1 or 2)
When it displaces to a new tile during resolution
Then its fortified_turns resets to 0 — the stance is lost the moment it actually moves"
            },
            %{
              kind: "happy path",
              title: "Stance ramps to full after a boundary held untouched",
              body: "Given a unit fortified this turn (fortified_turns 1) that neither moves nor attacks
When the turn boundary runs advance_fortify
Then fortified_turns bumps to 2 (the full bonus, capped there); being attacked in between never clears it"
            },
            %{
              kind: "happy path",
              title: "A blocked step does not clear fortify",
              body: "Given a fortified unit whose queued step is blocked so it never leaves its tile
When resolution applies positions
Then because its tile is unchanged its fortified_turns is preserved — only actual displacement clears the stance"
            },
            %{
              kind: "failure path",
              title: "Fortify is rejected for a non-defend-capable unit",
              body: "Given a unit whose type cannot defend-fortify (e.g. a barbarian, not player-commandable)
When a fortify command is issued
Then it is refused with {:error, :not_fortifiable} (or :not_owner if the caller does not own it)"
            }
          ]
        },
        %{
          statement: "A unit may only path over tiles its type permits: land units over land, the galley over coastal water only, and the Scout ignores the difficult-terrain surcharge.",
          scenarios: [
            %{
              kind: "happy path",
              title: "Galley paths over coastal water",
              body: "Given a galley on a coastal-water tile with a coastal-water route to the destination
When a move is queued
Then it paths over coastal-water tiles only (V1 scope: no deep ocean, no land)"
            },
            %{
              kind: "happy path",
              title: "Scout ignores the difficult-terrain surcharge",
              body: "Given a Scout (story 931) entering hills or woods with no road
When the entry cost is priced
Then it costs 1, not 2 — the Scout ignores the difficult-terrain surcharge (Civ 6 Scout ignore-terrain-cost trait), and its pathing reflects the cheaper cost too"
            },
            %{
              kind: "failure path",
              title: "Galley onto land is impassable",
              body: "Given a galley and a land destination tile
When a move is queued
Then it is refused with {:error, :impassable} — a galley may never enter land"
            },
            %{
              kind: "failure path",
              title: "Land unit onto water is impassable",
              body: "Given a land unit (warrior/worker/settler/lord) and a coastal-water or ocean destination tile
When a move is queued
Then it is refused with {:error, :impassable} — no land unit boards water in V1 scope"
            }
          ]
        }
      ],
      questions: [
        %{body: "Should an :interrupted (blocked) move order AUTO-RESUME next tick when the blocking tile clears, or stay stopped until the player re-issues it (current behavior)? Today a blocked step flips the order to :interrupted and it is never retried until re-queued — the root of the \"my Lord is a turn behind / won't move\" playtest reports. Civ 6 analog: a unit given a move-to order keeps pathing toward the target each turn until it arrives or is manually stopped, which argues for auto-resume (and possibly re-pathing around a now-persistent obstacle). PM decides: (a) keep stopped, (b) auto-resume same path when clear, or (c) auto-repath each tick.", status: :open, resolution: nil},
        %{body: "Capture/vassalization/rebellion resolves on an immediate move but not on a tick-continued one. queue_move/4 runs Vassalization.apply_captures and War.process_rebellion_endings right after move_now, so an immediately-resolved arrival triggers capture and rebellion-ending fallout instantly. But Turn.tick's Movement.resolve_orders (the boundary continuation of a long remaining path) runs neither hook. So a unit that reaches a captureable tile via the turn-boundary continuation may not trigger capture the same way a unit that reached it on the issuing tick does. Is this intended (captures only on player-issued moves) or a gap that should also fire on tick-continued arrivals? PM/dev to decide.", status: :open, resolution: nil},
        %{body: "Scout's \"ignore difficult-terrain cost\" (931) has no home in the cost model yet. entry_cost/3 today takes (world, roads, tile_id) with no unit-type parameter, and both Dijkstra pathfinding (bfs_path) and the per-step spend (attempt_step) read it as the single source of truth. Implementing the Scout discount means threading unit_type into entry_cost so BOTH the route choice and the step cost see cost 1 for the Scout — meaning a Scout would path straight THROUGH forests rather than around them, not just pay less. Is that the intended behavior (discount affects routing too), and does it stack cleanly with the already-1 road cost? PM/dev to confirm the intended cost-model shape before 931 is built.", status: :open, resolution: nil}
      ],
      note: nil
    }
  },
  %{
    story_id: 957,
    status: :in_progress,
    title: "Rivers — terrain feature",
    description:
      "As a player, I want rivers on the map, so the world feels natural and rivers carry the gameplay effects players expect (fresh water, yield/adjacency bonuses, movement, and river-gated buildings like the Water Mill).

Currently Broken Oaths does NOT model rivers at all (the Water Mill dropped Civ 6's river-adjacency requirement for this reason; Yields notes river gold as a \"deferred fork\"). This is a substantial terrain-generation feature on the Goldberg globe, not a quick fix.

Scope to work out in Three Amigos (Civ 6-grounded): river GENERATION on the sphere (rivers run along tile EDGES, not tiles — how to represent edges/adjacency on the Goldberg mesh; deterministic from the seed like the rest of terrain); which effects rivers grant (Civ 6: fresh water/housing — but we have no housing; combat penalty crossing a river; +gold or +yield adjacency; unlocks/boosts for river-adjacent buildings such as the Water Mill and, later, Mills/Aqueducts); movement cost to cross; rendering rivers on the canvas board; persistence (derived from seed, so no storage, per the game-state-persistence ADR). Depends on the globe mesh (925 movement model, terrain generator). Likely its own epic.",
    tags: [%{name: "unknown"}],
    criteria: [
    ],
    qa: %{final: :untested, attempts: 0, history: []},
    three_amigos: %{
      persona: nil,
      rules: [
      ],
      questions: [
      ],
      note: nil
    }
  }
]
