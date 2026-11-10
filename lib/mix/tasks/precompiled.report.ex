# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Mix.Tasks.Precompiled.Report do
  @shortdoc "Sends the last build's HIT/MISS/FAIL report to the precompiled source"
  @moduledoc """
  Sends what the last build in this `_build` (this `MIX_ENV` and
  `MIX_TARGET`: run it with the same ones as the build) hit, missed and
  failed to the configured source, so misses can be analysed and fixed.
  It shows exactly what will be sent and asks first.

      mix precompiled.report                    # show, ask, send
      mix precompiled.report --yes              # no question (CI)
      mix precompiled.report --contact @me      # a handle for follow-up questions
      mix precompiled.report --dump             # print the exact JSON, send nothing
      mix precompiled.report --dump out.json    # write it to a file, send nothing

  Without `--yes` only `y` or `yes` sends; anything else, and a stdin that
  is not interactive, counts as no.

  Sent: each dependency's name, version, HIT/MISS/FAIL and reason code; the
  Elixir and OTP versions, OS family and architecture, target and Nerves
  system; and the public Hex lock entries of those dependencies. Never sent:
  the project name, paths, host or user name, config values, environment
  variables, private package names. The answer to a new report is its id,
  printed once; it is all it takes to retract the report
  (`DELETE <source>/reports/<id>`). Sending the same report again is
  answered with "already received" and no id.

  A shortened `--dump` of a host project. A package from a private Hex
  organisation in the same lock appears nowhere, and the checksums are cut
  short here only:

  ```json
  {
    "format": 1,
    "client": "0.4.0",
    "built_at": "2026-11-10T14:02:11Z",
    "elixir": "1.20.3",
    "otp": 29,
    "os": {"family": "unix", "arch": "aarch64-apple-darwin"},
    "target": "host",
    "contact": "@my-github-handle",
    "lines": [
      {"name": "jason", "version": "1.4.4", "status": "hit",
       "reason_code": "hit", "reason_args": [], "reason": "installed"},
      {"name": "phoenix", "version": "1.8.1", "status": "miss",
       "reason_code": "closure_mismatch",
       "reason_args": ["telemetry", "1.2.1", "1.3.0"],
       "reason": "built against telemetry 1.2.1, lock has 1.3.0"}
    ],
    "lock": [
      {"name": "jason", "version": "1.4.4", "checksum": "bbbbbbbb…"},
      {"name": "phoenix", "version": "1.8.1", "checksum": "ffffffff…"},
      {"name": "telemetry", "version": "1.3.0", "checksum": "22222222…"}
    ]
  }
  ```

  The full example is in the
  [Troubleshooting guide](troubleshooting.md#an-example).

  Reporting never fails anything: any error is one line and the task exits 0.
  It reads nothing but the report and the lock, and changes nothing in
  `_build`.
  """
  use Mix.Task
  alias Precompiled.{Config, Report}

  @impl Mix.Task
  def run(args) do
    {opts, _rest} =
      OptionParser.parse!(dump_arg(args),
        strict: [yes: :boolean, contact: :string, dump: :string]
      )

    Mix.Project.get!()

    case Config.load() do
      nil ->
        Mix.shell().info("precompiled: off; nothing to report")

      config ->
        _ =
          Report.run(
            %{
              build_lib: Path.join(Mix.Project.build_path(), "lib"),
              lock: Mix.Dep.Lock.read(),
              config: config,
              project_dir: File.cwd!(),
              env: Atom.to_string(Mix.env()),
              target: Atom.to_string(Mix.target()),
              app: Mix.Project.config()[:app]
            },
            yes: Keyword.get(opts, :yes, false),
            contact: opts[:contact],
            dump: dump(opts[:dump])
          )
    end

    :ok
  end

  @doc false
  # OptionParser has no optional values: a bare `--dump` (last, or before
  # another flag) becomes `--dump -`, which prints.
  @spec dump_arg([String.t()]) :: [String.t()]
  def dump_arg([]), do: []
  def dump_arg(["--dump"]), do: ["--dump", "-"]

  def dump_arg(["--dump", "--" <> _ = next | rest]),
    do: ["--dump", "-" | dump_arg([next | rest])]

  def dump_arg([arg | rest]), do: [arg | dump_arg(rest)]

  defp dump(nil), do: nil
  defp dump("-"), do: :stdout
  defp dump(path), do: path
end
