cask "prism" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/moderniselife/prism/releases/download/v#{version}/Prism.app.zip"
  name "Prism"
  desc "Run every AI app and account side by side in isolated profiles"
  homepage "https://prism.mojolayers.com/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Prism.app"

  # Prism is ad-hoc signed, not notarised: clear quarantine so
  # Gatekeeper doesn't block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Prism.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.mojolayers.prism.plist",
    "~/Library/Saved Application State/com.mojolayers.prism.savedState",
  ]
end
