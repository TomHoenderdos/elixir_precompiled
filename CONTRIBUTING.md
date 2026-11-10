# Contributing

## Development

```
mix test                                 # unit tests, fixture server on port 4000
TEST_SERVER_PORT=4567 mix test           # when port 4000 is taken (the three ports above it are also used)
mix test --only integration              # child Mix projects against the fixture (needs hex.pm)
mix test --only production               # install/2 against the public portal
scripts/container-check.sh               # the same inside the compatibility worker image
MIX_ENV=prod mix archive.build           # precompiled-<vsn>.ez
```
