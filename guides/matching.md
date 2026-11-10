# What matches

A dependency is a candidate when it comes from Hex (a git or path
dependency never is), is not Nerves tooling (`nerves`, its own
dependencies, `nerves_system_*`, `nerves_toolchain_*`, `nerves_bootstrap`,
`precompiled` itself) and is not in `:except`. A build of a
candidate is installed only when every rule holds:

1. **Target.** The build is `pure_elixir` (it serves every system and
   plain Elixir), or it was made for this project's Nerves system at the
   exact system version in `mix.lock`.
2. **Elixir.** Same major and minor as the running Elixir, and the running
   version is at least the one the build was made with. Elixir code compiled
   on 1.20.1 runs on 1.20.3, not the other way round; versions compare as
   versions, so a 1.21.0 build is not served to 1.21.0-rc.0, while a
   1.21.0-rc.0 build is served to 1.21.0.
3. **OTP.** The same OTP major. What a build inlines at compile time from
   OTP headers (record layouts) can change between majors.
4. **Dependency env.** The build was compiled in the env the dependency
   compiles in here: `prod`, unless the project's `deps` entry overrides it
   with `env:`.
5. **Checksum.** The build's package checksum equals the dependency's
   checksum in `mix.lock`.
6. **Dependencies.** Every dependency the build was compiled against is in
   `mix.lock` at the same version and checksum, and every dependency the
   package declares (optional ones included) that the lock has was in the
   build.
7. **compile_env.** Every `Application.compile_env` value the build read
   equals the project's config for that key.
8. **Compile-time inputs.** A dependency whose own sources read
   `Mix.target()` at compile time (module level in `lib/`, anywhere in
   `mix.exs`) gets no `pure_elixir` build on a device target. It gets a
   system build only when the build was made under the project's target
   name: the recorded one, or else the system's conventional one
   (`nerves_system_rpi4` → `rpi4`). A dependency that reads an environment
   variable at module level in `lib/` never matches, nor does one whose
   sources cannot be scanned (they do not parse, or are over 2 MB a file or
   20 MB a package). Not covered: environment variables read in a
   dependency's `mix.exs`, and `Application.get_env` in a module body
   (Elixir warns about it). Builds record neither, so such a dependency
   can be served a build made with other values.

When several builds pass, the one already installed wins (its bytes stay as
they are), then the one made on the running Elixir patch, the closest older
patch, `pure_elixir` before a system build, and the newest run. When none
passes, the line gives the rule the build that got furthest broke, for
example `MISS  built with Elixir 1.20.3, running 1.20.1`.
