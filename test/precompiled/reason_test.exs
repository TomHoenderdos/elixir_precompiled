# SPDX-FileCopyrightText: 2026 Tom Hoenderdos
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Precompiled.ReasonTest do
  use ExUnit.Case, async: true
  alias Precompiled.Reason

  @shared ~w(hit not_in_batch not_built_version not_built_target build_method_unknown
             build_method_override build_method_mismatch malformed_entry rule8_unscannable
             rule8_env rule8_target build_predates toolchain_elixir toolchain_otp
             dep_env_differs checksum_differs closure_mismatch closure_checksum closure_absent
             closure_without compile_env_differs excepted revoked_provenance
             revoked_not_in_batch remove_failed deadline_passed fetch_failed verify_failed
             install_failed internal system_version_abi toolchain_otp_minor
             needed_lib_missing symbol_version_missing system_unknown system_bound_compile
             env_differs env_set_at_build env_all config_unrecorded config_order_differs)a

  test "the codes are exactly the table shared with the portal" do
    assert Reason.codes() == @shared
    assert length(Reason.codes()) == 41
  end

  test "the codes for matching across releases render their templates" do
    for {code, args, text} <- [
          {:system_version_abi, ["nerves_system_rpi4", "2.1.0", "15.3", "2.3.0", "15.4"],
           "built for nerves_system_rpi4 2.1.0 (toolchain 15.3), project has 2.3.0 (toolchain 15.4)"},
          {:toolchain_otp_minor, ["28.2.0", "28.1.0"], "built on OTP 28.2.0, release has 28.1.0"},
          {:needed_lib_missing, ["libssl.so.3"], "libssl.so.3 missing on target"},
          {:symbol_version_missing, ["libstdc++.so.6", "GLIBCXX_3.4.32"],
           "libstdc++.so.6 lacks GLIBCXX_3.4.32"},
          {:system_unknown, ["nerves_system_rpi4", "2.4.0"],
           "nerves_system_rpi4 2.4.0 not yet known to the portal"},
          {:system_bound_compile, [], "reads the Nerves system at compile time"}
        ] do
      assert Reason.render(code, args) == text
      assert Reason.new(code, args).text == text
    end
  end

  test "templates render args and never the text a reason was made from" do
    for code <- Reason.codes() do
      r =
        Reason.new(
          code,
          ["/home/me/acme", "https://pkgs.acme.example/x", "1.2.3"],
          "at /home/me/acme"
        )

      rendered = Reason.render(r.code, r.args)
      refute rendered =~ "/home"
      refute rendered =~ "https://"
      refute rendered =~ "acme"
      assert r.text == "at /home/me/acme"
    end
  end

  test "rendering fills placeholders, and ? for a missing argument" do
    assert Reason.render(:toolchain_elixir, ["1.20.3", "1.20.1"]) ==
             "built with Elixir 1.20.3, running 1.20.1"

    assert Reason.render(:not_built_target, ["nerves_system_rpi4"]) ==
             "not built for nerves_system_rpi4 ?"

    assert Reason.render(:compile_env_differs, ["ash", "spark"]) ==
             "compile_env differs: ash, spark"
  end

  test "arguments are names and versions only" do
    assert Reason.clean_args(["jason", "1.4.5", "1.21.0-rc.0", "nerves_system_rpi4", "", 29]) ==
             ["jason", "1.4.5", "1.21.0-rc.0", "nerves_system_rpi4", "", "29"]

    assert Reason.clean_args(["a b", "/tmp/x", "http://x", String.duplicate("a", 65), %{}, nil]) ==
             ["?", "?", "?", "?", "?", "?"]

    assert length(Reason.clean_args(Enum.map(1..12, &"a#{&1}"))) == 8
    assert Reason.clean_args("not a list") == []
  end

  test "a code string maps back without creating atoms" do
    assert Reason.code("not_built_target") == :not_built_target
    assert Reason.code("no_such_code_ever_#{System.unique_integer()}") == :internal
    assert Reason.code(nil) == :internal
  end

  test "an unknown code is a programming error" do
    assert_raise ArgumentError, fn -> Reason.new(:no_such_code, []) end
  end

  test "batch errors: unavailable is a fetch, anything else a verification" do
    assert %Reason{
             code: :fetch_failed,
             text: "batch unavailable: Status 503 x (installed build kept)"
           } =
             Reason.of_batch_error("batch unavailable: Status 503 x", " (installed build kept)")

    for why <- ["batch signature invalid", "batch stale: issued ...", "root signature invalid"] do
      assert %Reason{code: :verify_failed, text: ^why} = Reason.of_batch_error(why, "")
    end
  end

  test "manifest results" do
    assert {:ok, %{}} = Reason.of_manifest({:ok, %{}})
    assert {:miss, %Reason{code: :fetch_failed}} = Reason.of_manifest({:miss, "no manifest"})

    assert {:unreachable, %Reason{code: :fetch_failed}} =
             Reason.of_manifest({:unreachable, "offline: manifest not cached"})

    assert {:fail, %Reason{code: :verify_failed}} =
             Reason.of_manifest({:fail, "manifest hash differs from batch"})

    assert {:fail, %Reason{code: :install_failed}} =
             Reason.of_manifest({:fail, "cache refused (/x is not a regular file; remove it)"})
  end

  test "install results" do
    for {text, code} <- [
          {"downloaded .app: compile_env differs: ash [:x]", :compile_env_differs},
          {"downloaded .app names other 1.0.0", :verify_failed},
          {"staged .app unreadable", :verify_failed},
          {"size mismatch (ebin/a.beam)", :verify_failed},
          {"sha256 mismatch (ebin/a.beam)", :verify_failed},
          {"file larger than declared size (ebin/a.beam)", :verify_failed},
          {"file not available: abc (Status 404 Not Found)", :fetch_failed},
          {"offline: file not cached (ebin/a.beam)", :fetch_failed},
          {"install failed: eacces", :install_failed},
          {"provenance write failed: :enospc", :install_failed},
          {"cache refused (/x changed while being read)", :install_failed}
        ] do
      assert {:fail, %Reason{code: ^code, text: ^text}} = Reason.of_install({:fail, text})
    end

    assert :kept = Reason.of_install(:kept)
    assert {:hit, %{}} = Reason.of_install({:hit, %{}})
    r = Reason.new(:internal, [])
    assert {:fail, ^r} = Reason.of_install({:fail, r})
  end

  test "textual turns a coded outcome back into the printed one" do
    assert {:miss, "x"} = Reason.textual({:miss, Reason.new(:internal, [], "x")})
    assert :ok = Reason.textual(:ok)
    assert {:ok, %{}, "t"} = Reason.textual({:ok, %{}, "t"})
  end

  test "the compile-input codes render their templates" do
    for {code, args, text} <- [
          {:env_differs, ["GITHUB_ACTIONS"], "built with a different GITHUB_ACTIONS"},
          {:env_set_at_build, ["CI"],
           "built with CI set at compile time; a device cannot check its firmware's build environment"},
          {:env_all, [], "reads the whole environment at compile time"},
          {:config_unrecorded, [], "compile-time config reads not recorded"},
          {:config_order_differs, ["phoenix_view", "template_engines"],
           "compile-time config phoenix_view template_engines would differ in this project"}
        ] do
      assert Reason.new(code, args).text == text
    end
  end

  test "the release that reads builds_with_inputs is 0.6.0" do
    assert Mix.Project.config()[:version] == "0.6.0"
    assert File.read!("CHANGELOG.md") =~ "## v0.6.0"
  end
end
