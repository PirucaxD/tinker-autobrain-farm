---@meta
---lib/position_data.lua - playable Dota position (1-5) sets per hero.
---
---TINKER-ONLY. Nothing else requires this file. It is deliberately NOT in
---lib/hero_value.lua: that module is shared with Lina (Lina.lua:55 reads it
---for the Flame Cloak flip sum) and its tables are scalars feeding a number
---contract, which a set-valued entry would break.
---
---Data-only Tier 2, no API calls, no callbacks, no side effects.
---
---=== THE HAZARD, READ THIS BEFORE EDITING ===
---A WRONG NARROW ENTRY IS WORSE THAN A MISSING ONE.
---A missing hero returns ALL from Of(), the classifier fails to resolve, and
---the caller falls back to today's HeroValue.IsCore path - i.e. exactly
---current behaviour, never worse. A wrong NARROW entry instead produces a
---CONFIDENT assignment that flips IsCore, which is the precise defect class
---this data exists to remove. Worse, the consumer resolves positions by
---constraint elimination, so one bad entry can mis-assign the whole team,
---not one hero. WHEN UNSURE, WIDEN. Never trim a set to make elimination
---resolve more often.
---
---=== SOURCE ===
---dota2protracker.com/meta, mmr=7000, period=8, patch 7.41, harvested
---2026-08-13. Five separate per-position meta lists (pos 1..5), joined to
---lib/hero_data.lua keys via d2pt's own npc field (exact join, nothing
---inferred). Membership rule: hero appears in position P's set iff it has
--->= 200 games at P in that sample (~0.25% of the ~79,170 games per
---position). 200 is not a taste call: d2pt hard-truncates the pos-2 and
---pos-3 lists at 200 and the tail below could not be retrieved, so 200 is
---the only floor applicable uniformly to all five positions. At that floor
---the harvest still captures 97.7% / 100% / 100% / 96.4% / 97.1% of the
---games played at positions 1/2/3/4/5 respectively.
---
---HAND-CURATED AND META-DRIFTING. No tool in tools/ regenerates this. The
---position a hero is played at is a property of the patch and the meta, not
---of the KV data - it is provably NOT derivable from KV: grouping heroes by
---Bot.LaningInfo (SoloDesire, RequiresFarm, RequiresBabysit) puts Dazzle and
---Earthshaker in the same bucket. Re-curate by hand after a big patch. The
---trailing comment on each row is that hero's raw pos1/pos2/pos3/pos4/pos5
---match counts from the snapshot, kept so a later editor can see the
---evidence rather than re-guess it.
---
---=== MARKED ROWS ===
---  WIDENED  - a position was ADDED that the harvest did not show, because
---             d2pt truncated the pos-2 / pos-3 lists at 200 games and a 0
---             there means "unknown", not "never". Only interior gaps are
---             filled (the hero already plays both a lower AND a higher
---             position), and only at 2 and 3. Positions 1/4/5 were
---             harvested complete, so a low count there is an observation
---             and is left alone. Widening is the cheap direction: it costs
---             resolving power, never correctness.
---  OPERATOR - supplied directly by the operator and kept even where the
---             harvest disagrees. The disagreement is printed on the row.
---
---=== NOT COVERED ===
---Heroes with no row here get ALL from Of(). That is a legal, safe answer,
---not a bug. Absence from a d2pt list means "under 200 games at that
---position in this snapshot", never "cannot play that position", so absence
---is never read as a hard exclusion. npc_dota_hero_chen is deliberately
---left out: its only harvested play is 189 pos-5 and 26 pos-4 games, both
---under the floor, and writing a support-only set from below-floor evidence
---is exactly the wrong-narrow move.
---
---Usage:
---```lua
---local PositionData = require("lib.position_data")
---local cand = PositionData.Of(ally_name)   -- always a non-empty {ints}
---```

local PositionData = {}

---Every position, in ascending order. The answer for any hero this table
---does not cover. Never nil, never {}.
PositionData.ALL = { 1, 2, 3, 4, 5 }

---Positions a hero is actually played at, ascending ints in 1..5.
---Trailing comment = raw pos1/pos2/pos3/pos4/pos5 match counts (see header).
PositionData.PLAYABLE = {
    npc_dota_hero_abaddon                    = { 5             },  -- 46/0/0/100/607
    npc_dota_hero_abyssal_underlord          = { 3             },  -- 0/0/2725/13/15
    npc_dota_hero_alchemist                  = { 1             },  -- 438/0/0/78/76
    npc_dota_hero_ancient_apparition         = { 4, 5          },  -- 0/0/0/313/1257
    npc_dota_hero_antimage                   = { 1             },  -- 1737/0/0/12/6
    npc_dota_hero_arc_warden                 = { 2             },  -- 38/1127/0/17/12
    npc_dota_hero_axe                        = { 3             },  -- 0/0/5155/83/56
    npc_dota_hero_bane                       = { 4, 5          },  -- 0/0/0/777/3009
    npc_dota_hero_batrider                   = { 3             },  -- 0/0/466/155/69
    npc_dota_hero_beastmaster                = { 2, 3          },  -- 50/238/1651/5/5
    npc_dota_hero_bloodseeker                = { 1             },  -- 269/0/0/4/12
    npc_dota_hero_bounty_hunter              = { 4, 5          },  -- 0/0/0/3713/439
    npc_dota_hero_brewmaster                 = { 3             },  -- 0/0/1604/20/8
    npc_dota_hero_bristleback                = { 3             },  -- 102/0/923/7/3
    npc_dota_hero_broodmother                = { 2             },  -- 176/313/0/5/1
    npc_dota_hero_centaur                    = { 3             },  -- 21/0/2995/13/16
    npc_dota_hero_chaos_knight               = { 1, 2, 3       },  -- 336/0/440/25/18           WIDENED +2
    npc_dota_hero_clinkz                     = { 1, 2          },  -- 1352/218/0/19/3
    npc_dota_hero_crystal_maiden             = { 4, 5          },  -- 0/0/0/502/2453
    npc_dota_hero_dark_seer                  = { 3             },  -- 0/0/3159/11/2
    npc_dota_hero_dark_willow                = { 4, 5          },  -- 0/0/0/2052/725
    npc_dota_hero_dawnbreaker                = { 2, 3          },  -- 30/214/5726/117/93
    npc_dota_hero_dazzle                     = { 5             },  -- 0/0/0/182/1405            OPERATOR (harvest said {5})
    npc_dota_hero_death_prophet              = { 2, 3          },  -- 0/575/759/48/105
    npc_dota_hero_disruptor                  = { 4, 5          },  -- 0/0/0/484/3070
    npc_dota_hero_doom_bringer               = { 3             },  -- 142/0/3251/71/27
    npc_dota_hero_dragon_knight              = { 2, 3          },  -- 80/365/332/7/0
    npc_dota_hero_drow_ranger                = { 1             },  -- 2843/0/0/5/8
    npc_dota_hero_earth_spirit               = { 2, 3, 4, 5    },  -- 0/3198/565/1956/252
    npc_dota_hero_earthshaker                = { 2, 3, 4, 5    },  -- 0/2115/1187/1252/142      UNION of operator {3,4,5} and harvest {2,3,4}. Both sources carry real evidence (2115 observed pos-2 games; the operator asserts he is also played support), so the WIDEN rule applies rather than picking a side. COSTS NOTHING IN THE NORMAL CASE: with Tinker pinned to mid, 2 is struck by elimination and this reduces to exactly the operator {3,4,5}; it is only different, and only better, when Tinker is NOT mid.
    npc_dota_hero_elder_titan                = { 5             },  -- 0/0/0/107/437
    npc_dota_hero_ember_spirit               = { 2             },  -- 60/6557/0/30/9
    npc_dota_hero_enchantress                = { 3, 4, 5       },  -- 0/0/222/490/1003
    npc_dota_hero_enigma                     = { 3             },  -- 0/0/2982/93/65
    npc_dota_hero_faceless_void              = { 1             },  -- 2499/0/0/12/13
    npc_dota_hero_furion                     = { 1, 2, 3, 4, 5 },  -- 934/443/346/430/255
    npc_dota_hero_grimstroke                 = { 4, 5          },  -- 0/0/0/1537/1328
    npc_dota_hero_gyrocopter                 = { 1, 2, 3, 4, 5 },  -- 656/0/0/284/234           WIDENED +2,3
    npc_dota_hero_hoodwink                   = { 4, 5          },  -- 0/0/0/4832/1474
    npc_dota_hero_huskar                     = { 2             },  -- 65/1064/0/27/40
    npc_dota_hero_invoker                    = { 2, 3, 4       },  -- 0/6884/0/772/194          WIDENED +3
    npc_dota_hero_jakiro                     = { 4, 5          },  -- 0/0/0/271/1028
    npc_dota_hero_juggernaut                 = { 1             },  -- 2555/0/0/7/5
    npc_dota_hero_keeper_of_the_light        = { 2, 3, 4, 5    },  -- 0/2984/0/2146/330         WIDENED +3
    npc_dota_hero_kez                        = { 1, 2          },  -- 2042/751/0/7/6
    npc_dota_hero_kunkka                     = { 2, 3          },  -- 33/449/761/22/7
    npc_dota_hero_largo                      = { 3, 4, 5       },  -- 0/0/1314/343/356
    npc_dota_hero_legion_commander           = { 3             },  -- 0/0/2180/11/0
    npc_dota_hero_leshrac                    = { 1, 2          },  -- 206/1133/0/48/23
    npc_dota_hero_lich                       = { 4, 5          },  -- 0/0/0/651/3353
    npc_dota_hero_life_stealer               = { 1             },  -- 4351/0/0/5/12
    npc_dota_hero_lina                       = { 1, 2, 3, 4    },  -- 1130/8046/0/251/104       WIDENED +3
    npc_dota_hero_lion                       = { 2, 3, 4, 5    },  -- 0/522/0/3012/2643         WIDENED +3
    npc_dota_hero_lone_druid                 = { 1, 2          },  -- 1231/438/0/6/13
    npc_dota_hero_luna                       = { 1             },  -- 6930/0/0/6/6
    npc_dota_hero_lycan                      = { 3             },  -- 0/0/1474/22/3
    npc_dota_hero_magnataur                  = { 2, 3, 4, 5    },  -- 59/643/2194/474/286
    npc_dota_hero_marci                      = { 2, 3, 4, 5    },  -- 98/516/501/368/483
    npc_dota_hero_mars                       = { 3             },  -- 0/0/2017/40/16
    npc_dota_hero_medusa                     = { 1             },  -- 575/0/0/3/3
    npc_dota_hero_meepo                      = { 1, 2          },  -- 231/597/0/2/3
    npc_dota_hero_mirana                     = { 4, 5          },  -- 58/0/0/3823/2579
    npc_dota_hero_monkey_king                = { 1, 2          },  -- 652/499/0/71/17
    npc_dota_hero_morphling                  = { 1             },  -- 1926/0/0/3/4
    npc_dota_hero_muerta                     = { 1, 2, 3, 4    },  -- 1371/0/0/213/60           WIDENED +2,3
    npc_dota_hero_naga_siren                 = { 1             },  -- 465/0/0/4/16
    npc_dota_hero_necrolyte                  = { 1, 2, 3       },  -- 2032/1928/2237/5/9
    npc_dota_hero_nevermore                  = { 1, 2          },  -- 6737/2174/0/21/16
    npc_dota_hero_night_stalker              = { 3             },  -- 22/0/4777/71/16
    npc_dota_hero_nyx_assassin               = { 4, 5          },  -- 0/0/0/2060/252
    npc_dota_hero_obsidian_destroyer         = { 2             },  -- 97/2002/0/63/32
    npc_dota_hero_ogre_magi                  = { 2, 3, 4, 5    },  -- 0/206/282/383/1483
    npc_dota_hero_omniknight                 = { 3, 5          },  -- 0/0/223/82/563
    npc_dota_hero_oracle                     = { 4, 5          },  -- 0/0/0/264/1959
    npc_dota_hero_pangolier                  = { 2, 3          },  -- 0/1872/897/8/2
    npc_dota_hero_phantom_assassin           = { 1             },  -- 1507/0/0/2/3
    npc_dota_hero_phantom_lancer             = { 1             },  -- 6241/0/0/2/10
    npc_dota_hero_phoenix                    = { 2, 3, 4, 5    },  -- 0/485/763/1017/992
    npc_dota_hero_primal_beast               = { 2, 3          },  -- 0/691/1299/14/5
    npc_dota_hero_puck                       = { 2             },  -- 0/4011/0/8/3
    npc_dota_hero_pudge                      = { 2, 3, 4, 5    },  -- 176/582/2417/3963/2627
    npc_dota_hero_pugna                      = { 4, 5          },  -- 0/0/0/506/549
    npc_dota_hero_queenofpain                = { 2             },  -- 25/2901/0/166/42
    npc_dota_hero_rattletrap                 = { 4, 5          },  -- 0/0/0/1587/1960
    npc_dota_hero_razor                      = { 1, 2, 3       },  -- 340/214/828/31/29
    npc_dota_hero_riki                       = { 1, 2          },  -- 360/327/0/88/15
    npc_dota_hero_ringmaster                 = { 4, 5          },  -- 0/0/0/2249/2658
    npc_dota_hero_rubick                     = { 2, 3, 4, 5    },  -- 0/867/0/6577/1504         WIDENED +3
    npc_dota_hero_sand_king                  = { 2, 3          },  -- 0/421/491/14/2
    npc_dota_hero_shadow_demon               = { 4, 5          },  -- 0/0/0/539/627
    npc_dota_hero_shadow_shaman              = { 4, 5          },  -- 0/0/0/1049/1682
    npc_dota_hero_shredder                   = { 2, 3          },  -- 0/264/2954/22/5
    npc_dota_hero_silencer                   = { 4, 5          },  -- 0/0/0/566/1613
    npc_dota_hero_skeleton_king              = { 1, 2, 3       },  -- 488/0/663/9/4             WIDENED +2
    npc_dota_hero_skywrath_mage              = { 2, 3, 4, 5    },  -- 0/291/0/2547/621          WIDENED +3
    npc_dota_hero_slardar                    = { 2, 3          },  -- 0/493/2061/19/9
    npc_dota_hero_slark                      = { 1             },  -- 2539/0/0/121/41
    npc_dota_hero_snapfire                   = { 2, 3, 4, 5    },  -- 23/2245/985/2851/1658
    npc_dota_hero_sniper                     = { 2             },  -- 165/1371/0/103/57
    npc_dota_hero_spectre                    = { 1             },  -- 5863/0/0/15/17
    npc_dota_hero_spirit_breaker             = { 3, 4, 5       },  -- 0/0/317/4808/671
    npc_dota_hero_storm_spirit               = { 2             },  -- 82/3347/0/6/7
    npc_dota_hero_sven                       = { 1             },  -- 3554/0/0/14/18
    npc_dota_hero_techies                    = { 4, 5          },  -- 0/0/0/2522/970
    npc_dota_hero_templar_assassin           = { 1             },  -- 1455/0/0/1/1
    npc_dota_hero_terrorblade                = { 1             },  -- 2797/0/0/11/5
    npc_dota_hero_tidehunter                 = { 3             },  -- 0/0/2751/25/16
    npc_dota_hero_tinker                     = { 2             },  -- 36/2026/0/42/20
    npc_dota_hero_tiny                       = { 1, 2, 3, 4    },  -- 1967/534/0/558/73         WIDENED +3
    npc_dota_hero_treant                     = { 4, 5          },  -- 0/0/0/860/7383
    npc_dota_hero_troll_warlord              = { 1             },  -- 569/0/0/5/0
    npc_dota_hero_tusk                       = { 4, 5          },  -- 0/0/0/1720/3168
    npc_dota_hero_undying                    = { 3, 4, 5       },  -- 0/0/1601/968/4928
    npc_dota_hero_ursa                       = { 1             },  -- 1353/0/0/3/9
    npc_dota_hero_vengefulspirit             = { 1, 2, 3, 4, 5 },  -- 1161/0/732/393/541        WIDENED +2
    npc_dota_hero_venomancer                 = { 4, 5          },  -- 0/0/0/420/731
    npc_dota_hero_viper                      = { 2, 3          },  -- 64/1141/831/53/77
    npc_dota_hero_visage                     = { 2, 3          },  -- 0/396/644/153/73
    npc_dota_hero_void_spirit                = { 2, 3          },  -- 45/2533/291/46/6
    npc_dota_hero_warlock                    = { 5             },  -- 0/0/0/106/1244
    npc_dota_hero_weaver                     = { 1, 2, 3, 4    },  -- 538/0/0/530/168           WIDENED +2,3
    npc_dota_hero_windrunner                 = { 1, 2, 3, 4, 5 },  -- 2139/697/1304/2199/458
    npc_dota_hero_winter_wyvern              = { 3, 4, 5       },  -- 0/0/855/959/2724
    npc_dota_hero_wisp                       = { 1, 2, 3, 4, 5 },  -- 835/981/287/520/1395
    npc_dota_hero_witch_doctor               = { 4, 5          },  -- 0/0/0/475/1856
    npc_dota_hero_zuus                       = { 2, 3, 4, 5    },  -- 0/887/0/2256/1072         WIDENED +3
}

---The single position the hero is played at MOST in the snapshot - the
---operator's tie-breaker when elimination stalls. Always a member of the
---hero's PLAYABLE set. For an OPERATOR row it is the most-played position
---*inside the operator's set*, not the global argmax.
PositionData.PREFERRED = {
    npc_dota_hero_abaddon                    = 5,
    npc_dota_hero_abyssal_underlord          = 3,
    npc_dota_hero_alchemist                  = 1,
    npc_dota_hero_ancient_apparition         = 5,
    npc_dota_hero_antimage                   = 1,
    npc_dota_hero_arc_warden                 = 2,
    npc_dota_hero_axe                        = 3,
    npc_dota_hero_bane                       = 5,
    npc_dota_hero_batrider                   = 3,
    npc_dota_hero_beastmaster                = 3,
    npc_dota_hero_bloodseeker                = 1,
    npc_dota_hero_bounty_hunter              = 4,
    npc_dota_hero_brewmaster                 = 3,
    npc_dota_hero_bristleback                = 3,
    npc_dota_hero_broodmother                = 2,
    npc_dota_hero_centaur                    = 3,
    npc_dota_hero_chaos_knight               = 3,
    npc_dota_hero_clinkz                     = 1,
    npc_dota_hero_crystal_maiden             = 5,
    npc_dota_hero_dark_seer                  = 3,
    npc_dota_hero_dark_willow                = 4,
    npc_dota_hero_dawnbreaker                = 3,
    npc_dota_hero_dazzle                     = 5,
    npc_dota_hero_death_prophet              = 3,
    npc_dota_hero_disruptor                  = 5,
    npc_dota_hero_doom_bringer               = 3,
    npc_dota_hero_dragon_knight              = 2,
    npc_dota_hero_drow_ranger                = 1,
    npc_dota_hero_earth_spirit               = 2,
    npc_dota_hero_earthshaker                = 4,
    npc_dota_hero_elder_titan                = 5,
    npc_dota_hero_ember_spirit               = 2,
    npc_dota_hero_enchantress                = 5,
    npc_dota_hero_enigma                     = 3,
    npc_dota_hero_faceless_void              = 1,
    npc_dota_hero_furion                     = 1,
    npc_dota_hero_grimstroke                 = 4,
    npc_dota_hero_gyrocopter                 = 1,
    npc_dota_hero_hoodwink                   = 4,
    npc_dota_hero_huskar                     = 2,
    npc_dota_hero_invoker                    = 2,
    npc_dota_hero_jakiro                     = 5,
    npc_dota_hero_juggernaut                 = 1,
    npc_dota_hero_keeper_of_the_light        = 2,
    npc_dota_hero_kez                        = 1,
    npc_dota_hero_kunkka                     = 3,
    npc_dota_hero_largo                      = 3,
    npc_dota_hero_legion_commander           = 3,
    npc_dota_hero_leshrac                    = 2,
    npc_dota_hero_lich                       = 5,
    npc_dota_hero_life_stealer               = 1,
    npc_dota_hero_lina                       = 2,
    npc_dota_hero_lion                       = 4,
    npc_dota_hero_lone_druid                 = 1,
    npc_dota_hero_luna                       = 1,
    npc_dota_hero_lycan                      = 3,
    npc_dota_hero_magnataur                  = 3,
    npc_dota_hero_marci                      = 2,
    npc_dota_hero_mars                       = 3,
    npc_dota_hero_medusa                     = 1,
    npc_dota_hero_meepo                      = 2,
    npc_dota_hero_mirana                     = 4,
    npc_dota_hero_monkey_king                = 1,
    npc_dota_hero_morphling                  = 1,
    npc_dota_hero_muerta                     = 1,
    npc_dota_hero_naga_siren                 = 1,
    npc_dota_hero_necrolyte                  = 3,
    npc_dota_hero_nevermore                  = 1,
    npc_dota_hero_night_stalker              = 3,
    npc_dota_hero_nyx_assassin               = 4,
    npc_dota_hero_obsidian_destroyer         = 2,
    npc_dota_hero_ogre_magi                  = 5,
    npc_dota_hero_omniknight                 = 5,
    npc_dota_hero_oracle                     = 5,
    npc_dota_hero_pangolier                  = 2,
    npc_dota_hero_phantom_assassin           = 1,
    npc_dota_hero_phantom_lancer             = 1,
    npc_dota_hero_phoenix                    = 4,
    npc_dota_hero_primal_beast               = 3,
    npc_dota_hero_puck                       = 2,
    npc_dota_hero_pudge                      = 4,
    npc_dota_hero_pugna                      = 5,
    npc_dota_hero_queenofpain                = 2,
    npc_dota_hero_rattletrap                 = 5,
    npc_dota_hero_razor                      = 3,
    npc_dota_hero_riki                       = 1,
    npc_dota_hero_ringmaster                 = 5,
    npc_dota_hero_rubick                     = 4,
    npc_dota_hero_sand_king                  = 3,
    npc_dota_hero_shadow_demon               = 5,
    npc_dota_hero_shadow_shaman              = 5,
    npc_dota_hero_shredder                   = 3,
    npc_dota_hero_silencer                   = 5,
    npc_dota_hero_skeleton_king              = 3,
    npc_dota_hero_skywrath_mage              = 4,
    npc_dota_hero_slardar                    = 3,
    npc_dota_hero_slark                      = 1,
    npc_dota_hero_snapfire                   = 4,
    npc_dota_hero_sniper                     = 2,
    npc_dota_hero_spectre                    = 1,
    npc_dota_hero_spirit_breaker             = 4,
    npc_dota_hero_storm_spirit               = 2,
    npc_dota_hero_sven                       = 1,
    npc_dota_hero_techies                    = 4,
    npc_dota_hero_templar_assassin           = 1,
    npc_dota_hero_terrorblade                = 1,
    npc_dota_hero_tidehunter                 = 3,
    npc_dota_hero_tinker                     = 2,
    npc_dota_hero_tiny                       = 1,
    npc_dota_hero_treant                     = 5,
    npc_dota_hero_troll_warlord              = 1,
    npc_dota_hero_tusk                       = 5,
    npc_dota_hero_undying                    = 5,
    npc_dota_hero_ursa                       = 1,
    npc_dota_hero_vengefulspirit             = 1,
    npc_dota_hero_venomancer                 = 5,
    npc_dota_hero_viper                      = 2,
    npc_dota_hero_visage                     = 3,
    npc_dota_hero_void_spirit                = 2,
    npc_dota_hero_warlock                    = 5,
    npc_dota_hero_weaver                     = 1,
    npc_dota_hero_windrunner                 = 4,
    npc_dota_hero_winter_wyvern              = 5,
    npc_dota_hero_wisp                       = 5,
    npc_dota_hero_witch_doctor               = 5,
    npc_dota_hero_zuus                       = 4,
}

----------------------------------------------------------------------------
-- Of(name)
--
-- The playable-position set for a hero, or ALL when the hero is not covered.
-- NEVER returns nil and NEVER returns an empty table - an uncovered hero must
-- degrade to "could be anything", which leaves the caller at today's
-- behaviour rather than a confident wrong answer.
--
-- The returned table is shared, not a copy. Treat it as read-only.
--
-- Signature: (name: string|nil) -> { int, ... }  (1 <= #result <= 5)
----------------------------------------------------------------------------
function PositionData.Of(name)
    if type(name) ~= "string" then
        return PositionData.ALL
    end
    return PositionData.PLAYABLE[name] or PositionData.ALL
end

----------------------------------------------------------------------------
-- PreferredOf(name)
--
-- The tie-breaker position, or nil when the hero is not covered. nil here is
-- deliberate and legal: no evidence means no preference, and the caller must
-- fall through rather than invent one.
--
-- Signature: (name: string|nil) -> int|nil
----------------------------------------------------------------------------
function PositionData.PreferredOf(name)
    if type(name) ~= "string" then
        return nil
    end
    return PositionData.PREFERRED[name]
end

-- ---- observed-lane helpers (v0.1.379) ---------------------------------------------------------
-- Pure. They live here rather than in Tinker.lua because the main chunk sits AT Lua's 200-local
-- ceiling (three more top-level `local function`s threw "too many local variables"), and because
-- position logic belongs with the position data. The per-tick TALLY stays hero-side: it needs
-- State/now/Lane and it is four lines at the one site that already has the ally name and position.

---Resolve a per-ally lane tally { top, mid, bot, n } to an observed lane, or nil.
---Requires BOTH a minimum sample count AND a dominant share. A single sample is worthless:
---Lane._assign_lane is a coarse diagonal band accepting ~38% of the map whose mid region contains
---the ROSHAN PIT and the river centre, so a warding or Rosh-watching support accumulates mid
---samples. Only sustained dominance means anything.
---@return string|nil lane, number share
function PositionData.ObservedLane(h, min_n, min_share)
    if not h or (h.n or 0) < (min_n or 12) then return nil, 0 end
    local best, bn = nil, -1
    for _, ln in ipairs({ "top", "mid", "bot" }) do
        if (h[ln] or 0) > bn then best, bn = ln, (h[ln] or 0) end
    end
    local share = bn / math.max(1, h.n)
    if share < (min_share or 0.60) then return nil, share end
    return best, share
end

---The position set a lane can hold, from the point of view of `team` (2 = Radiant, 3 = Dire).
---Radiant safelane is BOT, Dire safelane is TOP. Standard layout: safelane {1,5}, offlane {3,4},
---mid {2}. INTERSECT this with the hero's playable set, never substitute it - so a genuinely odd
---lineup narrows to EMPTY and reads UNDETERMINED rather than confidently wrong.
---@return table set  keyed by position number
function PositionData.LaneSlots(lane, team)
    if lane == "mid" then return { [2] = true } end
    local safe = (team == 2) and "bot" or "top"
    if lane == safe then return { [1] = true, [5] = true } end
    return { [3] = true, [4] = true }
end

---Residual playable-position sets for a list of ally names, narrowed by naked-single elimination.
---HERO ASSUMPTION (kept verbatim from the Tinker main chunk, which is the only caller): position 2
---is struck from every ally set because Tinker holds mid himself. That is why this lives in a file
---whose header already declares itself TINKER-ONLY.
---@return table cand  name -> set of still-possible positions (keyed by position number)
function PositionData.Shadow(names)
    local cand = {}
    for _, n in ipairs(names) do
        local s = {}
        for _, v in ipairs(PositionData.Of(n)) do s[v] = true end
        s[2] = nil                                  -- the mid pin: Tinker owns 2
        cand[n] = s
    end
    local changed = true                            -- naked singles to fixpoint
    while changed do
        changed = false
        for n, s in pairs(cand) do
            local cnt, only = 0, nil
            for v in pairs(s) do cnt = cnt + 1; only = v end
            if cnt == 1 then
                for n2, s2 in pairs(cand) do
                    if n2 ~= n and s2[only] then s2[only] = nil; changed = true end
                end
            end
        end
    end
    return cand
end

return PositionData
