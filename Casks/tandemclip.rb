cask "tandemclip" do
  # "<short>,<build>": the appcast emits both sparkle:shortVersionString and
  # sparkle:version, and Homebrew's Sparkle livecheck strategy reports them as one
  # comma value. Pinning only the short version fails `brew audit --online` with
  # "differs from ... retrieved by livecheck" and breaks autobumping.
  version "0.24.1,60"
  sha256 "2bdaffd30edd5999a412d60fe556bdb9dce0bd631c24b463c4cd4d2775ee4131"

  url "https://tandemclip.com/TandemClip_#{version.csv.first}_aarch64.dmg",
      verified: "tandemclip.com/"
  name "TandemClip"
  desc "LAN-only clipboard sync for Macs"
  homepage "https://tandemclip.com/"

  # TandemClip auto-updates via Sparkle; track the signed appcast for new versions.
  livecheck do
    url "https://tandemclip.com/appcast.xml"
    strategy :sparkle
  end

  auto_updates true
  depends_on macos: :ventura
  depends_on arch: :arm64

  app "TandemClip.app"

  zap trash: [
    "~/Library/Application Support/TandemClip",
    "~/Library/Caches/com.tandemclip",
    "~/Library/HTTPStorages/com.tandemclip",
    "~/Library/Preferences/com.tandemclip.plist",
  ]
  # NOTE: the pairing code and device key live in the login Keychain
  # (service "com.tandemclip*") and are intentionally not removed by `zap`.
end
