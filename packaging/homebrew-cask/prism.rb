cask "prism" do
  version "__VERSION__"
  sha256 "__SHA256__"

  url "https://github.com/moderniselife/prism/releases/download/tui-v#{version}/Prism.app.zip"
  name "Prism"
  desc "Manage isolated Cursor profiles"
  homepage "https://github.com/moderniselife/prism"

  app "Prism.app"
end
