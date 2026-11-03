# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule ChainTest.DeployTest do
  # FakeBin changes the global PATH.
  use ExUnit.Case, async: false

  alias ChainTest.{Deploy, FakeBin, Preflight, Result}

  @moduletag :tmp_dir

  @uuid "30be4482-7e87-555e-9718-3e4e4d5e961f"
  @old "11111111-2222-3333-4444-555555555555"

  setup %{tmp_dir: tmp} do
    fw = Path.join(tmp, "chain_fixture.fw")
    File.write!(fw, "firmware bytes")
    known_hosts = Path.join(tmp, "known_hosts")
    File.write!(known_hosts, "")
    %{fw: fw, known_hosts: known_hosts}
  end

  defp fwup(uuid \\ @uuid, platform \\ "rpi4") do
    """
    echo 'meta-product=chain_fixture'
    echo 'meta-platform=#{platform}'
    echo 'meta-uuid="#{uuid}"'
    """
  end

  # A fake ssh: `-s <host> fwup` copies stdin to `uploaded` and exits
  # `upload_exit`; every other call answers the next of `answers`
  # (`{exit, output}`), repeating the last one.
  defp ssh(answers, upload_exit \\ 0) do
    cases =
      answers
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {{exit, out}, i} ->
        "  #{i}) printf '%s\\r\\n' '#{out}'; exit #{exit};;"
      end)

    last = length(answers)

    """
    d=$(dirname "$0")
    case " $* " in
      *" -s "*) cat > "$d/uploaded"; echo 'fwup: 100%'; exit #{upload_exit};;
    esac
    n=$(cat "$d/polls" 2>/dev/null || echo 0); n=$((n + 1)); echo $n > "$d/polls"
    [ $n -gt #{last} ] && n=#{last}
    case $n in
    #{cases}
    esac
    """
  end

  defp answer(uuid, uptime_ms), do: {0, "chain-deploy uuid=#{uuid} uptime_ms=#{uptime_ms}"}

  defp run(ctx, opts \\ []) do
    Deploy.run(
      Map.merge(
        %{
          device: "dev.local",
          known_hosts: ctx.known_hosts,
          fw_path: ctx.fw,
          target: "rpi4",
          poll_ms: 10,
          reboot_timeout_ms: 1_500
        },
        Map.new(opts)
      )
    )
  end

  defp by_check(results), do: Map.new(results, &{&1.check, &1})

  test "a good upload that reboots into the new firmware passes", ctx do
    stubs = %{
      "fwup" => fwup(),
      # Still up on the old firmware first, then down while it reboots,
      # then up on the new one.
      "ssh" =>
        ssh([
          answer(@old, 999_999_999),
          {255, "ssh: connect to host dev.local port 22: Connection refused"},
          answer(@uuid, 3)
        ])
    }

    FakeBin.with_stubs(stubs, fn dir ->
      {results, info} = run(ctx)
      r = by_check(results)

      assert Enum.map(results, & &1.check) == ~w(metadata upload reboot active_uuid)

      assert Enum.all?(results, &match?(%Result{step: :deploy, class: :pass}, &1)),
             inspect(results)

      assert info == %{expected_uuid: @uuid}
      assert r["active_uuid"].detail =~ @uuid

      assert File.read!(Path.join(dir, "uploaded")) == "firmware bytes"
      assert FakeBin.argv(dir, "fwup") == ["-m", "-i", ctx.fw]

      argv = FakeBin.argv(dir, "ssh")

      assert Enum.take(argv, length(Preflight.ssh_opts(ctx.known_hosts))) ==
               Preflight.ssh_opts(ctx.known_hosts)

      assert "StrictHostKeyChecking=yes" in argv
      assert List.last(argv) =~ ~s|Nerves.Runtime.KV.get_active("nerves_fw_uuid")|
      refute Enum.any?(argv, &(&1 =~ "accept-new"))
    end)
  end

  test "the upload is ssh -s <device> fwup with the pinned options", ctx do
    stubs = %{
      "fwup" => fwup(),
      "ssh" => """
      d=$(dirname "$0")
      case " $* " in
        *" -s "*) printf '%s\\n' "$@" > "$d/upload.argv"; cat > /dev/null; exit 0;;
      esac
      echo 'chain-deploy uuid=#{@uuid} uptime_ms=1'
      """
    }

    FakeBin.with_stubs(stubs, fn dir ->
      {_results, _} = run(ctx)
      argv = File.read!(Path.join(dir, "upload.argv")) |> String.split("\n", trim: true)
      assert argv == Preflight.ssh_opts(ctx.known_hosts) ++ ["-s", "dev.local", "fwup"]
    end)
  end

  test "an upload that exits 1 fails and leaves the reboot not exercised", ctx do
    FakeBin.with_stubs(%{"fwup" => fwup(), "ssh" => ssh([answer(@uuid, 1)], 1)}, fn dir ->
      {results, info} = run(ctx)
      r = by_check(results)

      assert r["metadata"].class == :pass
      assert r["upload"].class == :fail
      assert r["upload"].detail =~ "exit 1"
      assert r["reboot"].class == :not_exercised
      assert r["active_uuid"].class == :not_exercised
      assert info.expected_uuid == @uuid
      assert Result.exit_code(results) == 1
      # Only the upload ran: no poll after a failed upload.
      refute File.exists?(Path.join(dir, "polls"))
    end)
  end

  test "a device that boots back into the old firmware fails with both uuids", ctx do
    FakeBin.with_stubs(%{"fwup" => fwup(), "ssh" => ssh([answer(@old, 2)])}, fn _ ->
      {results, _} = run(ctx)
      r = by_check(results)

      assert r["upload"].class == :pass
      assert r["reboot"].class == :pass
      assert r["active_uuid"].class == :fail
      assert r["active_uuid"].detail =~ @uuid
      assert r["active_uuid"].detail =~ @old
    end)
  end

  test "a device that answers but never reboots fails the reboot", ctx do
    # The KV already names the new slot before the reboot; that must not pass.
    FakeBin.with_stubs(%{"fwup" => fwup(), "ssh" => ssh([answer(@uuid, 999_999_999)])}, fn _ ->
      {results, _} = run(ctx, reboot_timeout_ms: 300)
      r = by_check(results)

      assert r["reboot"].class == :fail
      assert r["reboot"].detail =~ "did not reboot"
      assert r["active_uuid"].class == :not_exercised
    end)
  end

  test "a device that never answers after the upload fails the reboot", ctx do
    stubs = %{"fwup" => fwup(), "ssh" => ssh([{255, "ssh: Connection refused"}])}

    FakeBin.with_stubs(stubs, fn _ ->
      {results, _} = run(ctx, reboot_timeout_ms: 300)
      r = by_check(results)

      assert r["reboot"].class == :fail
      assert r["reboot"].detail =~ "did not answer"
      assert r["reboot"].detail =~ "Connection refused"
      assert r["active_uuid"].class == :not_exercised
    end)
  end

  test "garbage around the answer is ignored, an echoed expression is not an answer", ctx do
    noisy =
      "Interactive Elixir (1.20.3)\r\n" <>
        ~s|IO.puts(["chain-deploy uuid=", to_string(x), " uptime_ms=", 1])\r\n| <>
        "chain-deploy uuid=#{@uuid} uptime_ms=4\r\n:ok"

    stubs = %{
      "fwup" => fwup(),
      "ssh" => """
      case " $* " in *" -s "*) cat > /dev/null; exit 0;; esac
      printf '%s' '#{noisy}'
      """
    }

    FakeBin.with_stubs(stubs, fn _ ->
      {results, _} = run(ctx)
      assert Enum.all?(results, &(&1.class == :pass)), inspect(results)
    end)
  end

  test "firmware without a meta-uuid fails the metadata check and uploads nothing", ctx do
    stubs = %{"fwup" => "echo 'meta-product=chain_fixture'", "ssh" => ssh([answer(@uuid, 1)])}

    FakeBin.with_stubs(stubs, fn dir ->
      {results, info} = run(ctx)
      r = by_check(results)

      assert r["metadata"].class == :fail
      assert r["metadata"].detail =~ "meta-uuid"
      assert r["upload"].class == :not_exercised
      assert info.expected_uuid == nil
      assert FakeBin.argv(dir, "ssh") == nil
    end)
  end

  test "firmware built for another platform is not uploaded", ctx do
    FakeBin.with_stubs(
      %{"fwup" => fwup(@uuid, "rpi0_2"), "ssh" => ssh([answer(@uuid, 1)])},
      fn dir ->
        {results, _} = run(ctx)
        r = by_check(results)

        assert r["metadata"].class == :fail
        assert r["metadata"].detail =~ "rpi0_2"
        assert r["upload"].class == :not_exercised
        assert FakeBin.argv(dir, "ssh") == nil
      end
    )
  end

  test "no firmware image leaves every check not exercised", ctx do
    {results, info} = run(ctx, fw_path: nil)

    assert Enum.map(results, & &1.check) == ~w(metadata upload reboot active_uuid)
    assert Enum.all?(results, &(&1.class == :not_exercised))
    assert info == %{expected_uuid: nil}
  end
end
