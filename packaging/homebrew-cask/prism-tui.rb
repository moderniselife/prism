cask "prism-tui" do
  version "__VERSION__"

  on_arm do
    sha256 "__SHA_ARM__"
    url "https://github.com/moderniselife/prism/releases/download/tui-v#{version}/prism-tui-darwin-arm64.tar.gz"
  end
  on_intel do
    sha256 "__SHA_INTEL__"
    url "https://github.com/moderniselife/prism/releases/download/tui-v#{version}/prism-tui-darwin-amd64.tar.gz"
  end

  name "Prism TUI"
  desc "Manage isolated Cursor profiles from the terminal"
  homepage "https://github.com/moderniselife/prism"

  binary "prism-tui"

  postflight do
    # Binaries are unsigned; clear quarantine so Gatekeeper
    # doesn't block first run on macOS.
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{staged_path}/prism-tui"]
  end
end
