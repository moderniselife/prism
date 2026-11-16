cask "prism-tui" do
  arch arm: "arm64", intel: "amd64"

  version "__VERSION__"
  sha256 arm:   "__SHA_ARM__",
         intel: "__SHA_INTEL__"
  url "https://github.com/moderniselife/prism/releases/download/v#{version}/prism-tui-darwin-#{arch}.tar.gz"

  name "Prism TUI"
  desc "Terminal app for running AI apps and accounts in isolated profiles"
  homepage "https://prism.mojolayers.com/"

  binary "prism-tui"

  # The binary is unsigned: clear quarantine so Gatekeeper
  # doesn't block the first run.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{staged_path}/prism-tui"]
  end
end
