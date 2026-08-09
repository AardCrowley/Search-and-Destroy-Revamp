-- seed_data.lua
-- One-time database seed: area start rooms, area name cross-references,
-- and mob keyword exceptions.
--
-- Downloaded by the bootstrap on first install, run once, then deleted.
-- _snd_seed_path must be set by the caller before dofile()-ing this file:
--   _snd_seed_path = "/path/to/seed_data.lua"
--   dofile(_snd_seed_path)
--
-- Depends on: db.lua, settings.lua (snd_get_setting / snd_set_setting)

-- ─── GUARD ────────────────────────────────────────────────────────────────────

if snd_get_setting("seed_data_applied", "") ~= "" then
    -- Already applied; clean up stale file if it exists.
    if _snd_seed_path then pcall(os.remove, _snd_seed_path) end
    return
end

-- ─── AREA DATA ────────────────────────────────────────────────────────────────
-- start: room ID for xrt/xrun navigation. -1 or 0 = unknown/inaccessible.
-- nq: 1 = not a questable area.
-- vid: 1 = area is in the Vidblain dimension (requires portal sequence).
-- ct: continent index (informational only; not stored in the DB schema).

local AREA_SEED = {
    -- Continents
    { k="abend",       name="The Dark Continent, Abend",              start=24909, ct=3 },
    { k="alagh",       name="Alagh, the Blood Lands",                 start=3224,  ct=4 },
    { k="gelidus",     name="Gelidus",                                start=18780, ct=2 },
    { k="mesolar",     name="The Continent of Mesolar",               start=12664, ct=0 },
    { k="southern",    name="The Southern Ocean",                     start=5192,  ct=1 },
    { k="uncharted",   name="The Uncharted Oceans",                   start=7701,  ct=5 },
    { k="vidblain",    name="Vidblain, the Ever Dark",                start=33570, ct=6, vid=1 },
    -- A
    { k="aardington",  name="Aardington Estate",                      start=47509 },
    { k="academy",     name="The Aylorian Academy",                   start=35233 },
    { k="adaldar",     name="Battlefields of Adaldar",                start=34400 },
    { k="afterglow",   name="Afterglow",                              start=38134 },
    { k="agroth",      name="The Marshlands of Agroth",               start=11027 },
    { k="ahner",       name="Kingdom of Ahner",                       start=30129 },
    { k="alehouse",    name="Wayward Alehouse",                       start=885   },
    { k="amazon",      name="The Amazon Nation",                      start=1409  },
    { k="amusement",   name="The Amusement Park",                     start=29282 },
    { k="andarin",     name="The Blighted Tundra of Andarin",         start=2399  },
    { k="annwn",       name="Annwn",                                  start=28963 },
    { k="anthrox",     name="Anthrox",                                start=3993  },
    { k="arboretum",   name="Arboretum",                              start=39100 },
    { k="arena",       name="The Gladiator's Arena",                  start=25768 },
    { k="arisian",     name="Arisian Realm",                          start=28144 },
    { k="ascent",      name="The First Ascent",                       start=43150 },
    { k="asherodan",   name="The Keep of the Asherodan",              start=37400, vid=1 },
    { k="astral",      name="The Astral Travels",                     start=27882 },
    { k="atlantis",    name="Atlantis",                               start=10573 },
    { k="autumn",      name="Eternal Autumn",                         start=13839 },
    { k="avian",       name="Avian Kingdom",                          start=4334  },
    { k="aylor",       name="The Grand City of Aylor",                start=32418 },
    -- B
    { k="bazaar",      name="Onyx Bazaar",                            start=34454 },
    { k="beer",        name="The Land of the Beer Goblins",           start=20062 },
    { k="believer",    name="The Path of the Believer",               start=25940 },
    { k="blackrose",   name="Black Rose",                             start=1817  },
    { k="bliss",       name="Wedded Bliss",                           start=29988 },
    { k="bonds",       name="Unearthly Bonds",                        start=23411 },
    -- C
    { k="caldera",     name="The Icy Caldera of Mauldoon",            start=26341 },
    { k="callhero",    name="The Call of Heroes",                     start=33031 },
    { k="camps",       name="Tournament Camps",                       start=4714  },
    { k="canyon",      name="Canyon Memorial Hospital",               start=25551 },
    { k="caravan",     name="Wayfarer's Caravan",                     start=16071 },
    { k="cards",       name="House of Cards",                         start=6255  },
    { k="carnivale",   name="Olde Worlde Carnivale",                  start=28635 },
    { k="cataclysm",   name="The Cataclysm",                          start=19976 },
    { k="cathedral",   name="The Old Cathedral",                      start=27497 },
    { k="cats",        name="Sheila's Cat Sanctuary",                 start=40900 },
    { k="chasm",       name="The Chasm and The Catacombs",            start=29446 },
    { k="chakra",      name="Chakra Spire",                           start=0     },
    { k="chantry",     name="Fellchantry",                            start=0     },
    { k="chessboard",  name="The Chessboard",                         start=25513 },
    { k="childsplay",  name="Child's Play",                           start=678   },
    { k="cineko",      name="Aerial City of Cineko",                  start=1507  },
    { k="citadel",     name="The Flying Citadel",                     start=14963 },
    { k="conflict",    name="Thandeld's Conflict",                    start=27711 },
    { k="coral",       name="The Coral Kingdom",                      start=4565  },
    { k="cougarian",   name="The Cougarian Queendom",                 start=14311 },
    { k="cove",        name="Kiksaadi Cove",                          start=49941 },
    { k="cradle",      name="Cradlebrook",                            start=11267 },
    { k="crynn",       name="Crynn's Church",                         start=43800 },
    -- D
    { k="damned",      name="Halls of the Damned",                    start=10469 },
    { k="darklight",   name="The DarkLight",                          start=19642, vid=1 },
    { k="darkside",    name="The Darkside of the Fractured Lands",    start=15060 },
    { k="ddoom",       name="Desert Doom",                            start=4193  },
    { k="deadlights",  name="The Deadlights",                         start=16856 },
    { k="deathtrap",   name="Deathtrap Dungeon",                      start=1767  },
    { k="deneria",     name="Realm of Deneria",                       start=35006 },
    { k="desert",      name="The Desert Prison",                      start=20186 },
    { k="desolation",  name="The Mountains of Desolation",            start=19532 },
    { k="dhalgora",    name="Dhal'Gora Outlands",                     start=16755 },
    { k="diatz",       name="The Three Pillars of Diatz",             start=1254  },
    { k="diner",       name="Tumari's Diner",                         start=36700 },
    { k="dortmund",    name="Dortmund",                               start=16577 },
    { k="drageran",    name="The Drageran Empire",                    start=25894 },
    { k="dread",       name="Dread Tower",                            start=26075 },
    { k="dsr",         name="Diamond Soul Revelation",                start=30030 },
    { k="dundoom",     name="The Dungeon of Doom",                    start=25661 },
    { k="dunes",       name="Dunes in Gold",                          start=42170 },
    { k="dungeon",     name="Bloodlust Dungeon",                      start=45933 },
    { k="dunoir",      name="Mount duNoir",                           start=14222 },
    { k="duskvalley",  name="Dusk Valley",                            start=37301 },
    { k="dynasty",     name="The Eighteenth Dynasty",                 start=30799 },
    -- E
    { k="earthlords",  name="The Earth Lords",                        start=42000 },
    { k="earthplane",  name="Earth Plane 4",                          start=1354  },
    { k="elemental",   name="Elemental Chaos",                        start=41624 },
    { k="empire",      name="The Empire of Aiighialla",               start=32203 },
    { k="empyrean",    name="Empyrean, Streets of Downfall",          start=14042 },
    { k="entropy",     name="The Archipelago of Entropy",             start=29773 },
    -- F
    { k="fantasy",     name="Fantasy Fields",                         start=15205 },
    { k="farm",        name="Kimr's Farm",                            start=10676 },
    { k="fayke",       name="All in a Fayke Day",                     start=30418 },
    { k="fens",        name="The Curse of the Midnight Fens",         start=16528 },
    { k="fields",      name="The Killing Fields",                     start=29232 },
    { k="firebird",    name="Realm of the Firebird",                  start=32885 },
    { k="firenation",  name="Realm of the Sacred Flame",              start=41879 },
    { k="fireswamp",   name="The Fire Swamp",                         start=34755 },
    { k="fortress",    name="The Goblin Fortress",                    start=31835 },
    { k="fortune",     name="Crossroads of Fortune",                  start=38561 },
    { k="fractured",   name="The Fractured Lands",                    start=17033 },
    { k="ft1",         name="Faerie Tales",                           start=1205  },
    { k="ftii",        name="Faerie Tales II",                        start=26673 },
    -- G
    { k="gallows",     name="Gallows Hill",                           start=4344  },
    { k="gathering",   name="The Gathering Horde",                    start=36451 },
    { k="gauntlet",    name="The Gauntlet",                           start=31652 },
    { k="gilda",       name="Gilda And The Dragon",                   start=4243  },
    { k="glamdursil",  name="The Glamdursil",                         start=35055 },
    { k="glimmerdim",  name="Brightsea and Glimmerdim",               start=26252 },
    { k="gnomalin",    name="Cloud City of Gnomalin",                 start=34397 },
    { k="goldrush",    name="Gold Rush",                              start=15014 },
    { k="graveyard",   name="The Graveyard",                          start=28918 },
    { k="greece",      name="Ancient Greece",                         start=2089  },
    { k="gwillim",     name="The Trouble with Gwillimberry",          start=25974 },
    -- H
    { k="hades",       name="Entrance to Hades",                      start=29161 },
    { k="hatchling",   name="Hatchling Aerie",                        start=34670 },
    { k="hawklord",    name="The Realm of the Hawklords",             start=40550 },
    { k="hedge",       name="Hedgehogs' Paradise",                    start=15146 },
    { k="helegear",    name="Helegear Sea",                           start=30699 },
    { k="hell",        name="Descent to Hell",                        start=30984 },
    { k="hoard",       name="Swordbreaker's Hoard",                   start=1675  },
    { k="hodgepodge",  name="A Magical Hodgepodge",                   start=30469 },
    { k="horath",      name="The Broken Halls of Horath",             start=91    },
    { k="horizon",     name="Nebulous Horizon",                       start=31959 },
    -- I
    { k="illoria",     name="The Tournament of Illoria",              start=10420 },
    { k="imagi",       name="Imagi's Nation",                         start=36800 },
    { k="imperial",    name="Imperial Nation",                        start=16966, vid=1 },
    { k="infamy",      name="The Realm of Infamy",                    start=26641 },
    { k="infest",      name="The Infestation",                        start=16165 },
    { k="insan",       name="Insanitaria",                            start=6850  },
    -- J
    { k="jenny",       name="Jenny's Tavern",                         start=29637 },
    { k="jotun",       name="Jotunheim",                              start=31508 },
    -- K
    { k="kearvek",     name="The Keep of Kearvek",                    start=29722 },
    { k="kerofk",      name="Kerofk",                                 start=16405 },
    { k="ketu",        name="Ketu Uplands",                           start=35114 },
    { k="kingsholm",   name="Kingsholm",                              start=27522 },
    { k="knossos",     name="The Great City of Knossos",              start=28193 },
    { k="kobaloi",     name="Keep of the Kobaloi",                    start=10691 },
    { k="kultiras",    name="Kul Tiras",                              start=31161 },
    -- L
    { k="lab",         name="Chaprenula's Laboratory",                start=28684 },
    { k="labyrinth",   name="The Labyrinth",                          start=31405 },
    { k="lagoon",      name="Black Lagoon",                           start=30549 },
    { k="landofoz",    name="The Land of Oz",                         start=510   },
    { k="laym",        name="Tai'rha Laym",                           start=6005  },
    { k="legend",      name="Land of Legend",                         start=16224 },
    { k="lemdagor",    name="Storm Ships of Lem-Dagor",               start=1966  },
    { k="lidnesh",     name="The Forest of Li'Dnesh",                 start=27995 },
    { k="livingmine",  name="Living Mines of Dak'Tai",                start=37008 },
    { k="logging",     name="Svrogan's Logging Camp",                 start=31254 },
    { k="longnight",   name="Into the Long Night",                    start=26367 },
    { k="losttime",    name="Island of Lost Time",                    start=28584 },
    { k="lowlands",    name="The Lowlands",                           start=28044 },
    { k="lplanes",     name="The Lower Planes",                       start=29364 }, -- shared entry point with uplanes; verify in-game
    -- M
    { k="maelstrom",   name="The Maelstrom",                          start=38058 },
    { k="manor",       name="Death's Manor",                          start=10621 },
    { k="masq",        name="Masquerade Island",                      start=29840 },
    { k="mayhem",      name="Artificer's Mayhem",                     start=1866  },
    { k="melody",      name="Art of Melody",                          start=14172 },
    { k="minos",       name="The Shadows of Minos",                   start=20472 },
    { k="mistridge",   name="The Covenant of Mistridge",              start=4491  },
    { k="monastery",   name="The Monastery",                          start=15756 },
    { k="mudwog",      name="Mudwog's Swamp",                         start=2347  },
    -- N
    { k="nanjiki",     name="Nanjiki Ruins",                          start=11203 },
    { k="necro",       name="Necromancers' Guild",                    start=29922 },
    { k="nenukon",     name="Nenukon and the Far Country",            start=31784 },
    { k="newthalos",   name="New Thalos",                             start=23853 },
    { k="ninehells",   name="The Nine Hells",                         start=4613  },
    { k="northstar",   name="Northstar",                              start=11127 },
    { k="nottingham",  name="Nottingham",                             start=11077 },
    { k="nulan",       name="Plains of Nulan'Boar",                   start=37900 },
    { k="nursing",     name="Ascension Bluff Nursing Home",           start=31977 },
    { k="nynewoods",   name="The Nyne Woods",                         start=23562 },
    -- O
    { k="oceanpark",   name="Andolor's Ocean Adventure Park",         start=39600 },
    { k="omentor",     name="The Witches of Omen Tor",                start=15579, vid=1 },
    { k="ooku",        name="Ookushka Garrison",                      start=39000 },
    { k="origins",     name="Tribal Origins",                         start=35900 },
    { k="orlando",     name="Hotel Orlando",                          start=30331 },
    -- P
    { k="paradise",    name="Paradise Lost",                          start=29624 },
    { k="partroxis",   name="The Partroxis",                          start=5814  },
    { k="peninsula",   name="Tairayden Peninsula",                    start=35701 },
    { k="petstore",    name="Giant's Pet Store",                      start=995   },
    { k="pompeii",     name="Pompeii",                                start=57    },
    { k="promises",    name="Foolish Promises",                       start=25819 },
    { k="prosper",     name="Prosper's Island",                       start=28268 },
    -- Q
    { k="qong",        name="Qong",                                   start=16115 },
    { k="quarry",      name="Gnoll's Quarry",                         start=23510 },
    -- R
    { k="radiance",    name="Radiance Woods",                         start=19805 },
    { k="raga",        name="Raganatittu",                            start=19861 },
    { k="raukora",     name="The Blood Opal of Rauko'ra",             start=6040  },
    { k="rebellion",   name="Rebellion of the Nix",                   start=10305 },
    { k="remcon",      name="The Reman Conspiracy",                   start=25837 },
    { k="reme",        name="The Imperial City of Reme",              start=32703 },
    { k="rosewood",    name="Rosewood Castle",                        start=6901  },
    { k="ruins",       name="The Ruins of Diamond Reach",             start=16805 },
    -- S
    { k="sagewood",    name="Sagewood Grove",                         start=28754 },
    { k="sahuagin",    name="The Abyssal Caverns of Sahuagin",        start=34592 },
    { k="salt",        name="The Great Salt Flats",                   start=4538  },
    { k="sanctity",    name="Sanctity of Eternal Damnation",          start=10518 },
    { k="sanctum",     name="The Blood Sanctum",                      start=15307 },
    { k="sandcastle",  name="Sho'aram, Castle in the Sand",           start=37701 },
    { k="sanguine",    name="The Sanguine Tavern",                    start=15436 },
    { k="scarred",     name="The Scarred Lands",                      start=34036 },
    { k="sendhian",    name="Adventures in Sendhia",                  start=20288, vid=1 },
    { k="sennarre",    name="Sen'narre Lake",                         start=15491 },
    { k="shadowsend",  name="Shadow's End",                           start=40096 },
    { k="shouggoth",   name="The Temple of Shouggoth",                start=34087 },
    { k="siege",       name="Kobold Siege Camp",                      start=43265 },
    { k="sirens",      name="Siren's Oasis Resort",                   start=16298 },
    { k="slaughter",   name="The Slaughter House",                    start=1601  },
    { k="snuckles",    name="Snuckles Village",                       start=182   },
    { k="soh",         name="The School of Horror",                   start=25611 },
    { k="sohtwo",      name="The School of Horror 2",                 start=30752 },
    { k="solan",       name="The Town of Solan",                      start=23713 },
    { k="songpalace",  name="The Palace of Song",                     start=47013 },
    { k="spyreknow",   name="Guardian's Spyre of Knowledge",          start=34800 },
    { k="stone",       name="The Fabled City of Stone",               start=11386 },
    { k="storm",       name="Storm Mountain",                         start=6304  },
    { k="stormhaven",  name="The Ruins of Stormhaven",                start=20649 },
    { k="stronghold",  name="Dark Elf Stronghold",                    start=20572 },
    { k="stuff",       name="The Stuff of Shadows",                   start=40400 },
    -- T
    { k="takeda",      name="Takeda's Warcamp",                       start=15952 },
    { k="talsa",       name="The Empire of Talsa",                    start=26917 },
    { k="tanra",       name="Tanra'vea",                              start=46913 },
    { k="temple",      name="The Temple of Shal'indrael",             start=31597 },
    { k="terra",       name="The Cracks of Terra",                    start=19679 },
    { k="terramire",   name="Fort Terramire",                         start=4493  },
    { k="thieves",     name="Den of Thieves",                         start=7     },
    { k="tilule",      name="Tilule Rehabilitation Clinic",           start=39771 },
    { k="times",       name="Intrigues of Times Past",                start=28463 },
    { k="tirna",       name="Tir na nOg",                             start=20136 },
    { k="titan",       name="The Titans' Keep",                       start=38234 },
    { k="tol",         name="The Tree of Life",                       start=16325 },
    { k="tombs",       name="The Relinquished Tombs",                 start=15385 },
    -- U
    { k="umari",       name="Umari's Castle",                         start=36601 },
    { k="underdark",   name="The UnderDark",                          start=27341 },
    { k="uplanes",     name="The Upper Planes",                       start=29364 }, -- shared entry point with lplanes; verify in-game
    { k="uprising",    name="The Uprising",                           start=15382 },
    -- V
    { k="vale",        name="Sundered Vale",                          start=1036  },
    { k="verdure",     name="Verdure Estate",                         start=24090 },
    { k="verume",      name="Jungles of Verume",                      start=30607 },
    { k="village",     name="A Peaceful Giant Village",               start=30850 },
    { k="vlad",        name="Castle Vlad-Shamir",                     start=15970 },
    { k="volcano",     name="The Silver Volcano",                     start=6091  },
    -- W
    { k="weather",     name="Weather Observatory",                    start=40499 },
    { k="werewood",    name="The Were Wood",                          start=30956 },
    { k="wildwood",    name="Wildwood",                               start=322   },
    { k="winter",      name="Winterlands",                            start=1306  },
    { k="wizards",     name="War of the Wizards",                     start=31316 },
    { k="wonders",     name="Seven Wonders",                          start=32981 },
    { k="wooble",      name="The Wobbly Woes of Woobleville",         start=11335 },
    { k="woodelves",   name="The Wood Elves of Nalondir",             start=32199 },
    { k="wtc",         name="Warrior's Training Camp",                start=37895 },
    { k="wyrm",        name="The Council of the Wyrm",                start=28847 },
    -- X
    { k="xmas",        name="Christmas Vacation",                     start=6212  },
    { k="xylmos",      name="Xyl's Mosaic",                           start=472   },
    -- Y
    { k="yarr",        name="The Misty Shores of Yarr",               start=30281 },
    { k="ygg",         name="Yggdrasil: The World Tree",              start=24186 },
    { k="yurgach",     name="The Yurgach Domain",                     start=29450 },
    -- Z
    { k="zangar",      name="Zangar's Demonic Grotto",                start=6164  },
    { k="zenith",      name="An Auspicious Star's Zenith",            start=23681 },
    { k="zodiac",      name="Realm of the Zodiac",                    start=15857 },
    { k="zoo",         name="Aardwolf Zoological Park",               start=5920  },
    { k="zyian",       name="The Dark Temple of Zyian",               start=729   },
    -- Non-questable: Manor areas
    { k="manor1",      name="Death's Manor (1)",   start=14460, nq=1 },
    { k="manor3",      name="Death's Manor (3)",   start=20836, nq=1 },
    { k="manorisle",   name="Manor Isle",          start=6366,  nq=1 },
    { k="manormount",  name="Manor Mount",         start=39449, nq=1 },
    { k="manorsea",    name="Manor Sea",           start=35003, nq=1 },
    { k="manorville",  name="Manor Village",       start=35004, nq=1 },
    { k="manorwoods",  name="Manor Woods",         start=35002, nq=1 },
    -- Non-questable: Epic areas
    { k="blackclaw",   name="Blackclaw",           start=-1,    nq=1 },
    { k="geniewish",   name="A Genie's Last Wish", start=38464, nq=1 },
    { k="icefall",     name="Icefall",             start=38701, nq=1 },
    { k="inferno",     name="Inferno",             start=-1,    nq=1 },
    { k="oradrin",     name="Oradrin",             start=25436, nq=1 },
    { k="transcend",   name="Transcendence",       start=0,     nq=1 },
    { k="winds",       name="Winds of Fate",       start=39900, nq=1 },
    -- Non-questable: Other
    { k="badtrip",     name="Bad Trip",            start=32877, nq=1 },
    { k="birthday",    name="Birthday",            start=10920, nq=1 },
    { k="seaking",     name="Seaking",             start=-1,    nq=1 },
    -- Non-questable: Public clan halls
    { k="amazonclan",  name="Amazon Clan Hall",    start=34212, nq=1 },
    { k="bard",        name="Bard Hall",           start=30538, nq=1 },
    { k="bootcamp",    name="Boot Camp",           start=49256, nq=1 },
    { k="cabal",       name="Cabal Hall",          start=15704, nq=1 },
    { k="chaos",       name="Chaos Hall",          start=28909, nq=1 },
    { k="crimson",     name="Crimson Hall",        start=27989, nq=1 },
    { k="crusaders",   name="Crusaders Hall",      start=31122, nq=1 },
    { k="daoine",      name="Daoine Hall",         start=30949, nq=1 },
    { k="doh",         name="DoH Hall",            start=16803, nq=1 },
    { k="dominion",    name="Dominion Hall",       start=5863,  nq=1 },
    { k="dragon",      name="Dragon Hall",         start=642,   nq=1 },
    { k="druid",       name="Druid Hall",          start=29582, nq=1 },
    { k="emerald",     name="Emerald Hall",        start=831,   nq=1 },
    { k="gaardian",    name="Gaardian Hall",       start=20026, nq=1 },
    { k="imperium",    name="Imperium Hall",       start=30415, nq=1 },
    { k="light",       name="Light Hall",          start=2339,  nq=1 },
    { k="loqui",       name="Loqui Hall",          start=28580, nq=1 },
    { k="masaki",      name="Masaki Hall",         start=15852, nq=1 },
    { k="perdition",   name="Perdition Hall",      start=19968, nq=1 },
    { k="pyre",        name="Pyre Hall",           start=15141, nq=1 },
    { k="romani",      name="Romani Hall",         start=24180, nq=1 },
    { k="seekers",     name="Seekers Hall",        start=14165, nq=1 },
    { k="shadokil",    name="Shadokil Hall",       start=32407, nq=1 },
    { k="tanelorn",    name="Tanelorn Hall",       start=31561, nq=1 },
    { k="tao",         name="Tao Hall",            start=29210, nq=1 },
    { k="touchstone",  name="Touchstone Hall",     start=28346, nq=1 },
    { k="twinlobe",    name="Twinlobe Hall",       start=15575, nq=1 },
    { k="vanir",       name="Vanir Hall",          start=878,   nq=1 },
    { k="watchmen",    name="Watchmen Hall",       start=32342, nq=1 },
    -- Non-questable: Closed clan halls / inaccessible
    { k="baal",        name="Baal Hall",           start=-1, nq=1 },
    { k="hook",        name="Hook Hall",           start=-1, nq=1 },
    { k="retri",       name="Retribution Hall",    start=-1, nq=1 },
    { k="rhabdo",      name="Rhabdo Hall",         start=-1, nq=1 },
    { k="rogues",      name="Rogues Hall",         start=-1, nq=1 },
    { k="xunti",       name="Xunti Hall",          start=-1, nq=1 },
    { k="challenge",   name="Challenge Area",      start=-1, nq=1 },
    { k="immhomes",    name="Imm Homes",           start=-1, nq=1 },
    { k="lasertwo",    name="Laser 2",             start=-1, nq=1 },
    { k="limbo",       name="Limbo",               start=-1, nq=1 },
    { k="lualand",     name="Lualand",             start=-1, nq=1 },
    { k="midgaard",    name="Midgaard",            start=-1, nq=1 },
    { k="oldclanone",  name="Old Clan One",        start=-1, nq=1 },
    { k="oldclantwo",  name="Old Clan Two",        start=-1, nq=1 },
    { k="oldclanthr",  name="Old Clan Three",      start=-1, nq=1 },
    { k="oldclanfou",  name="Old Clan Four",       start=-1, nq=1 },
    { k="vault",       name="The Vault",           start=-1, nq=1 },
    { k="warzone",     name="War Zone",            start=-1, nq=1 },
    { k="wolfmaze",    name="Wolf Maze",           start=-1, nq=1 },
}

-- ─── KEYWORD EXCEPTIONS ───────────────────────────────────────────────────────

local KEYWORD_SEED = {
    ["aardington"] = { ["a very large portrait"]              = "large port" },
    ["alehouse"]   = {
        ["a dancing male patron"]                             = "dancing male",
        ["a dancing female patron"]                           = "dancing female",
    },
    ["anthrox"]    = {
        ["the little white rabbit"]                           = "rabb",
        ["the bee"]                                           = "worker bee",
        ["an escaped creature"]                               = "prisoner creature",
        ['a "business" man']                                  = "business man",
    },
    ["ddoom"]      = {
        ["a dangerous scorpion"]                              = "scorp",
        ["Lwji, the Sunrise great warrior"]                   = "lwji",
        ["Taji, the Sunset leader"]                           = "taji lead",
        ["Taji's personal advisor"]                           = "pers advi",
        ["Tjac, the Sunrise leader"]                          = "tjac lead",
        ["Tjac's personal advisor"]                           = "sunr advis",
        ["Yki, the great Sunset warrior"]                     = "yki",
    },
    ["deneria"]    = { ["High Priest of Miad'Bir"]            = "high miad" },
    ["desert"]     = { ["a village citizen"]                  = "citi" },
    ["fields"]     = { ["a mutated goat"]                     = "goat" },
    ["fortress"]   = {
        ["a grizzled goblin dressed in skins"]                = "grizz gobl",
        ["Blood Silk, Collector of souls, Queen of the spiders"] = "silk queen",
    },
    ["hell"]       = {
        ["a scrumptious chicken pot pie"]                     = "chicken pot pie",
        ["a yummy vegetable pot pie"]                         = "vegetable pot pie",
        ["a yummy beef pot pie"]                              = "beef pot pie",
    },
    ["illoria"]    = { ["the King and Queen's Guard"]         = "pers guard" },
    ["landofoz"]   = { ["one of Dorothy's uncles"]            = "doroth uncle" },
    ["laym"]       = { ["an elite guard of the church"]       = "elit guar" },
    ["livingmine"] = {
        ["a member of the 'Cal tribe"]                        = "memb cal",
        ["a member of the 'Sorr tribe"]                       = "memb sorr",
        ["a member of the 'Tai tribe"]                        = "memb tai",
        ["Dak'tai's shaman"]                                  = "dakt shama",
        ["the 'Tai chieftain"]                                = "tai chief",
    },
    ["longnight"]  = { ["Mr. Roberge"]                        = "car rober" },
    ["losttime"]   = {
        ["T-Rex"]                                             = "T-rex",
        ["Great White Shark"]                                 = "white shark",
    },
    ["manor"]      = {
        ["Aremata-Popua"]                                     = "aremata-pop",
        ["Aremata-Rorua"]                                     = "aremata-ror",
    },
    ["masq"]       = {
        ["a gentleman on the way to the ball"]                = "gentl",
        ["a very attractive woman"]                           = "attr woman",
    },
    ["necro"]      = { ["the head necromancer's assistant"]   = "old mage assist" },
    ["northstar"]  = {
        ["a Blood Ring elite warrior"]                        = "elit warr",
        ["Daryoon, a priest of nature"]                       = "dary pries",
        ["Tristam, the Prince of the Orcs"]                   = "trist orc",
    },
    ["sanctity"]   = { ["a half-converted human"]             = "human" },
    ["siege"]      = {
        ["a kobold eating lunch"]                             = "kobold eating",
        ["a large mole"]                                      = "mole",
        ["a very large firefly"]                              = "larg firef",
        ["the fattest kobold ever"]                           = "fat kobold",
        ["an oddly tall and clean kobold"]                    = "tall kobold",
    },
    ["snuckles"]   = {
        ["the snuckle"]                                       = "male snuckle",
        ["Sarah, the grieving snuckle"]                       = "sarah griev",
    },
    ["sohtwo"]     = {
        ["An evil form of Sagen"]     = "notcarlsagen",
        ["Angelic Demonspawn"]        = "angelic",
        ["Bubbly Obyron"]             = "fuzzybunny",
        ["Chatbot Kelaire"]           = "chatbot",
        ["Dejected Broud"]            = "dejected",
        ["Disagreeable Rumour"]       = "obstinate",
        ["Disoriented Dadrake"]       = "letsturnlefthere",
        ["Evil Aaeron"]               = "shinythings",
        ["Evil Althalus"]             = "homeskillet",
        ["Evil Belmont"]              = "bridgetroll",
        ["Evil Domain"]               = "66",
        ["Evil Euphonix"]             = "ragbrai",
        ["Evil Ghaan"]                = "longghaan",
        ["Evil Halo"]                 = "jackandcoke",
        ["Evil Ikyu"]                 = "ickypoo",
        ["Evil Justme"]               = "helperisme",
        ["Evil Kharpern"]             = "kittyimm",
        ["Evil KlauWaard"]            = "tricksy",
        ["Evil Kt"]                   = "ktkat",
        ["Evil Lasher"]               = "thearchitect",
        ["Evil Madcatz"]              = "mathizard",
        ["Evil Maerchyng"]            = "maerchyng",
        ["Evil Morrigu"]              = "morrigu",
        ["Evil OrcWarrior"]           = "sheepshagger",
        ["Evil Pane"]                 = "painintheneck",
        ["Evil Plaideleon"]           = "crazycanadian",
        ["Evil Rekhart"]              = "hartsawreck",
        ["Evil Sarlock"]              = "l33td00d",
        ["Evil Tela"]                 = "telllllllla",
        ["Evil Timeghost"]            = "floppyimm",
        ["Evil Tymme"]                = "hourglass",
        ["Evil Vladia"]               = "sexyvamp",
        ["Evil Whitdjinn"]            = "thundercat",
        ["Evil Windjammer"]           = "justsomeimm",
        ["Evil Wolfe"]                = "likeobybutbritish",
        ["Evil Xyzzy"]                = "weirdcode",
        ["Good Aerianne"]             = "pointyears",
        ["Good Cadaver"]              = "newbiehater",
        ["Good Delight"]              = "turkishdelight",
        ["Good Dirtworm"]             = "wormy",
        ["Good Eclaboussure"]         = "dropbearimm",
        ["Good Filt"]                 = "plainolefilt",
        ["Good Glimmer"]              = "betterhalfofclaire",
        ["Good Kinson"]               = "upgradeboy",
        ["Good Lumina"]               = "thievesrus",
        ["Good Oladon"]               = "spellingbee",
        ["Good Rhuli"]                = "rulistheworld",
        ["Good Sausage"]              = "fatbreakfast",
        ["Good Sirene"]               = "warriorprincess",
        ["Good Takihisis"]            = "dragonlady",
        ["Good Terrill"]              = "askcitron",
        ["Good Tripitaka"]            = "laketripitaka",
        ["Good Tyanon"]               = "tieoneon",
        ["Good Valkur"]               = "demonlord",
        ["Good Vilgan"]               = "unabridged",
        ["Good Xantcha"]              = "pokerimm",
        ["Good Zane"]                 = "inzanity",
        ["Goodie Goodie Jaenelle"]    = "goodie",
        ["Impatient Styliann"]        = "willyouhurryup",
        ["Kinda-Sorta Good Whisper"]  = "kinda",
        ["Master Shen"]               = "master",
        ["Mathematical Mordist"]      = "complex",
        ["Nascaard Rezit"]            = "nascaard",
        ["Pandemonium Penthesilea"]   = "pandemonium",
        ["Record Holding Guinness"]   = "cantwriteatall",
        ["Singing Paramore"]          = "failedmusician",
        ["Sith Lord Neeper"]          = "sith",
        ["Smurfy Laren"]              = "lovethemsmurfs",
        ["Sober Citron"]              = "sober",
        ["Socialite Arthon"]          = "airhead",
        ["Straight Dreamfyre"]        = "straight",
        ["The cool version of Xeno"]  = "onex",
        ["The Pancake Flat"]          = "pancake",
        ["Tjopping Quadrapus"]        = "tjopping",
        ["Unhelpful Claire"]          = "cookies",
        ["Unremarkable Korridel"]     = "unremarkable",
        ["Unrestrained Elvandar"]     = "omgsheneverstopstalking",
        ["Warsnail Anaristos"]        = "warsnail",
        ["Cuddlebear Koala"]          = "cuddlebear",
        ["(Helper) Fenix"]            = "helper",
    },
    ["stone"]      = { ["a Citadel of Stone Cityguard"]       = "cit guar" },
    ["talsa"]      = { ["a dwarven mercenary"]                = "dwar merc" },
    ["wooble"]     = { ["the Sea Snake Master-at-Arms"]       = "snake mast" },
    ["yarr"]       = {
        ["a pirate sorting the treasure"]                     = "pirat sort",
        ["a pirate stealing some treasure"]                   = "pirat steal",
    },
    ["zoo"]        = { ["a black-footed pine marten"]         = "pine marte" },
}

-- ─── SEED LOGIC ───────────────────────────────────────────────────────────────

local function seed()
    local db = db_open()
    local ok, err = pcall(function()
        execute_in_transaction(db, function(d)
            -- 1. Seed areas.
            for _, a in ipairs(AREA_SEED) do
                local sr = tonumber(a.start) or -1
                local sr_sql = (sr > 0) and tostring(sr) or "NULL"
                -- Insert row if key does not exist yet.
                d:exec(
                    "INSERT OR IGNORE INTO areas (key, name, start_room, noquest, vidblain, source) " ..
                    "VALUES (" ..
                    fixsql(a.k) .. ", " ..
                    fixsql(a.name) .. ", " ..
                    sr_sql .. ", " ..
                    (a.nq  and "1" or "0") .. ", " ..
                    (a.vid and "1" or "0") .. ", " ..
                    "'seed')"
                )
                -- For rows that already exist, fill in start_room if currently missing.
                if sr > 0 then
                    d:exec(
                        "UPDATE areas SET start_room=" .. sr_sql ..
                        " WHERE key=" .. fixsql(a.k) ..
                        " AND (start_room IS NULL OR start_room <= 0)"
                    )
                end
            end

            -- 2. Seed mob keyword exceptions (char_id NULL = global).
            -- Use WHERE NOT EXISTS because SQLite treats NULLs as distinct
            -- in UNIQUE constraints, so INSERT OR IGNORE does not protect us.
            for zone, mobs in pairs(KEYWORD_SEED) do
                for mob_name, kw in pairs(mobs) do
                    d:exec(
                        "INSERT INTO mob_keywords (char_id, zone, mob_name, keyword) " ..
                        "SELECT NULL, " .. fixsql(zone) .. ", " ..
                        fixsql(mob_name) .. ", " .. fixsql(kw) .. " " ..
                        "WHERE NOT EXISTS (" ..
                        " SELECT 1 FROM mob_keywords WHERE char_id IS NULL" ..
                        " AND zone=" .. fixsql(zone) ..
                        " AND mob_name=" .. fixsql(mob_name) .. ")"
                    )
                end
            end
        end)
    end)

    db_close(db)

    if not ok then
        ErrorNote("SnD: seed_data failed: " .. tostring(err))
        return
    end

    InfoNote("SnD: Seed data applied.")
    snd_set_setting("seed_data_applied", "1", true)

    -- Self-delete so this file is not kept on disk.
    if _snd_seed_path then
        local removed, rem_err = os.remove(_snd_seed_path)
        if not removed then
            DebugNote("SnD: Could not remove seed_data.lua: " .. tostring(rem_err))
        end
    end
end

seed()
