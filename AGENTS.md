# Project memory

- When modifying `bin/pi-container`, update and test both the detailed help menu and the brief usage summary for combined help arguments, including workspace/container lifecycle and agent-state lineage options.
- Agent-state discovery uses Docker volume metadata; the only persistent lineage pointer is `~/.config/pi-agent-containers/seed` by default. Keep missing-pointer confirmation and seed-repointing behavior documented and tested.
- This repo mirrors ../Claude-Code (`bin/claude-container`): the same concept gets the same function, variable, file, and test name in both; helper scripts that behave the same stay textually identical apart from tool names; port fixes both ways.
